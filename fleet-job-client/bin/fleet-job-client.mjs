#!/usr/bin/env node
// fleet-job-client — minimal dispatch endpoint for bare Claude Code agents.
//
// Stands in for the SideButton MCP server (port 9876) on variants that don't
// ship one (e.g. ubuntu-claude-code). Reproduces the subset of the SB HTTP
// surface that the portal's Temporal dispatch in
// website/temporal/src/activities/agent.ts actually calls:
//
//   GET  /health                          → liveness + state for fleetHealthSweep
//   GET  /api/running-workflows           → list of in-flight runs
//   GET  /api/runs/:runId                 → per-run status (for monitor loop)
//   POST /api/workflows/:workflowId/run   → dispatch endpoint — spawns claude
//   POST /api/clear-markers               → clear stale completion markers
//   POST /api/job-context                 → write job-context.json (used by Stop hook)
//   DELETE /api/job-context               → clear job-context.json
//
// Sends periodic POST /api/agents/heartbeat to the portal so the agent stays
// "online" without depending on the SB server's heartbeat cadence.
//
// Workflow dispatch is intentionally trivial: workflow_id is opaque, and we
// spawn `claude -p "$prompt"` where $prompt is built from params.hint (or a
// fallback that mentions the workflow_id + ticket_url). Knowledge-pack-aware
// workflows are out of scope for the bare variant — the SWE Bare profile
// exists to measure raw Claude Code without the SideButton runtime.
//
// Usage:
//   AGENT_TOKEN=... AGENT_NAME=... PORTAL_URL=https://sidebutton.com \
//     node fleet-job-client.mjs

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, unlinkSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.FLEET_CLIENT_PORT || 9876);
const PORTAL_URL = process.env.PORTAL_URL || 'https://sidebutton.com';
const AGENT_TOKEN = process.env.AGENT_TOKEN;
const AGENT_NAME = process.env.AGENT_NAME;
const AGENT_RUNNER = process.env.AGENT_RUNNER || 'ubuntu-claude-code';
const RUNNERS_REF = process.env.RUNNERS_REF || 'unknown';
const HEARTBEAT_INTERVAL_MS = 60_000;

if (!AGENT_TOKEN || !AGENT_NAME) {
  console.error('fleet-job-client: AGENT_TOKEN and AGENT_NAME are required');
  process.exit(2);
}

const HOME = homedir();
const STATE_DIR = join(HOME, '.sidebutton');
mkdirSync(STATE_DIR, { recursive: true });
const JOB_CONTEXT_PATH = join(STATE_DIR, 'job-context.json');
const LAST_TOOL_USE_PATH = join(STATE_DIR, 'last-tool-use');

/** run_id → { workflowId, status, startedAt, output, error, pid, completedAt } */
const runs = new Map();
let lastResult = null;

function nowIso() { return new Date().toISOString(); }

function readFileSyncSafe(path) {
  try { return readFileSync(path, 'utf8'); } catch { return ''; }
}

function buildPrompt(workflowId, params) {
  const hint = typeof params?.hint === 'string' ? params.hint.trim() : '';
  if (hint) return hint;
  const ticket = params?.ticket_url || params?.ticket_key;
  if (ticket) {
    return `Run workflow "${workflowId}" against ticket ${ticket}. Follow the relevant SE/QA/PM playbook for this repository.`;
  }
  return `Run workflow "${workflowId}". Inputs: ${JSON.stringify(params || {})}.`;
}

function spawnClaude(runId, workflowId, params) {
  const prompt = buildPrompt(workflowId, params);
  // --dangerously-skip-permissions matches the SB-server unattended invocation.
  // We pipe the prompt on stdin (rather than -p "...") so prompts > shell arg
  // limits still work; claude reads stdin when -p is supplied with `-`.
  const args = ['--dangerously-skip-permissions', '-p', '-'];
  const child = spawn('claude', args, {
    cwd: join(HOME, 'workspace'),
    env: { ...process.env, FLEET_RUN_ID: runId, FLEET_WORKFLOW_ID: workflowId },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const run = runs.get(runId);
  run.pid = child.pid;
  child.stdin.write(prompt);
  child.stdin.end();

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (b) => { stdout += b.toString('utf8'); });
  child.stderr.on('data', (b) => { stderr += b.toString('utf8'); });

  child.on('exit', (code) => {
    const r = runs.get(runId);
    if (!r) return;
    r.completedAt = nowIso();
    if (code === 0) {
      r.status = 'completed';
      r.output = stdout.slice(-4000) || `claude exited ${code}`;
      lastResult = { type: workflowId, at: r.completedAt };
    } else {
      r.status = 'failed';
      r.error = stderr.slice(-4000) || `claude exited ${code}`;
    }
    postStepComplete(r).catch((err) => {
      console.error(`[fleet-job-client] step-complete failed for run ${runId}:`, err.message);
    });
  });

  child.on('error', (err) => {
    const r = runs.get(runId);
    if (!r) return;
    r.status = 'failed';
    r.error = err.message;
    r.completedAt = nowIso();
    postStepComplete(r).catch(() => {});
  });
}

async function postStepComplete(run) {
  // step-complete relies on job_steps.sb_run_id matching the run_id we returned
  // to Temporal. The Temporal monitor loop also writes sb_run_id on its end,
  // so a same-value POST keeps both sides aligned.
  const payload = {
    sb_run_id: run.runId,
    status: run.status === 'completed' ? 'success' : 'failed',
    output_message: run.output || undefined,
    error: run.error || undefined,
  };
  const res = await fetch(`${PORTAL_URL}/api/jobs/step-complete`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${AGENT_TOKEN}`,
      'X-Agent-Name': AGENT_NAME,
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  }
}

async function postHeartbeat() {
  try {
    const res = await fetch(`${PORTAL_URL}/api/agents/heartbeat`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${AGENT_TOKEN}`,
        'X-Agent-Name': AGENT_NAME,
      },
      body: JSON.stringify({
        dependency_versions: {
          agent_runner: AGENT_RUNNER,
          runners_ref: RUNNERS_REF,
          fleet_job_client: '1.0.0',
        },
      }),
    });
    if (!res.ok) {
      console.warn(`[fleet-job-client] heartbeat HTTP ${res.status}`);
    }
  } catch (err) {
    console.warn('[fleet-job-client] heartbeat error:', err.message);
  }
}

function readLastToolUse() {
  try { return readFileSyncSafe(LAST_TOOL_USE_PATH).trim() || null; } catch { return null; }
}

function buildHealth() {
  const active = [...runs.values()].filter((r) => r.status === 'running');
  return {
    status: 'ok',
    runner: AGENT_RUNNER,
    has_extension: false,
    browser_connected: false,
    claude_running: active.length > 0,
    claude_sessions: active.map((r) => ({ pid: r.pid || 0, cmd: 'claude' })),
    workflows_running: active.length,
    last_tool_use: readLastToolUse(),
    idle_since: active.length === 0 ? nowIso() : null,
    result: lastResult,
    dependency_versions: {
      agent_runner: AGENT_RUNNER,
      runners_ref: RUNNERS_REF,
      fleet_job_client: '1.0.0',
    },
  };
}

function send(res, status, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': buf.length });
  res.end(buf);
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { return {}; }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const path = url.pathname;
  const method = req.method;

  try {
    if (method === 'GET' && path === '/health') return send(res, 200, buildHealth());

    if (method === 'GET' && path === '/api/running-workflows') {
      const workflows = [...runs.values()]
        .filter((r) => r.status === 'running')
        .map((r) => ({ run_id: r.runId, workflow_id: r.workflowId, started_at: r.startedAt }));
      return send(res, 200, { workflows });
    }

    if (method === 'GET' && path.startsWith('/api/runs/')) {
      const runId = path.slice('/api/runs/'.length);
      const r = runs.get(runId);
      if (!r) return send(res, 404, { error: 'run not found' });
      return send(res, 200, {
        run_log: {
          metadata: { status: r.status, output_message: r.output, error: r.error },
          output_message: r.output,
          events: r.error ? [{ message: r.error }] : [],
        },
      });
    }

    if (method === 'POST' && path.startsWith('/api/workflows/') && path.endsWith('/run')) {
      const workflowId = path.slice('/api/workflows/'.length, -'/run'.length);
      const body = await readBody(req);
      const runId = `bare-${randomUUID()}`;
      const run = {
        runId, workflowId, status: 'running', startedAt: nowIso(),
        output: null, error: null, pid: null, completedAt: null,
      };
      runs.set(runId, run);
      spawnClaude(runId, workflowId, body.params || {});
      return send(res, 200, { run_id: runId });
    }

    if (method === 'POST' && path === '/api/clear-markers') {
      lastResult = null;
      try { unlinkSync(LAST_TOOL_USE_PATH); } catch { /* missing is fine */ }
      return send(res, 200, { ok: true });
    }

    if (method === 'POST' && path === '/api/job-context') {
      const body = await readBody(req);
      writeFileSync(JOB_CONTEXT_PATH, JSON.stringify(body));
      return send(res, 200, { ok: true });
    }

    if (method === 'DELETE' && path === '/api/job-context') {
      try { unlinkSync(JOB_CONTEXT_PATH); } catch { /* missing is fine */ }
      return send(res, 200, { ok: true });
    }

    send(res, 404, { error: 'not found', path });
  } catch (err) {
    send(res, 500, { error: err.message });
  }
});

server.listen(PORT, () => {
  console.log(`[fleet-job-client] listening on :${PORT} (runner=${AGENT_RUNNER}, portal=${PORTAL_URL})`);
});

// Send the first heartbeat immediately so the portal flips status quickly,
// then settle into the interval cadence.
postHeartbeat();
setInterval(postHeartbeat, HEARTBEAT_INTERVAL_MS);
