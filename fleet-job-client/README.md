# fleet-job-client

A thin Node.js HTTP server that replaces the SideButton MCP server on bare
agents (variant `ubuntu-claude-code`). Stands in for `sidebutton serve` on the
exact same port (`:9876`) and implements the subset of the SB HTTP surface
that the portal's Temporal dispatch actually uses.

## Why

`website/temporal/src/activities/agent.ts` dispatches jobs to every agent the
same way: a `POST http://<agent-ip>:9876/api/workflows/<id>/run` plus polling
against `/health`, `/api/running-workflows`, and `/api/runs/<id>`. A bare
Claude Code agent — no SideButton runtime, no Chrome extension, no
knowledge-pack registry — still needs to answer those calls or the portal
will mark it `error`/`offline`. This client is the minimal answer.

It also fires periodic `POST /api/agents/heartbeat` so the agent's
`last_seen_at` stays fresh on the portal side without depending on the SB
server's heartbeat cadence.

## Contract

Endpoints implemented (subset of the SideButton MCP server's `:9876` surface):

| Method | Path | Used by |
|---|---|---|
| GET | `/health` | `temporal/activities/agent.ts` (monitor loop), `api/agents/health.ts` (fleet sweep) |
| GET | `/api/running-workflows` | monitor loop fallback (detect workflow finished) |
| GET | `/api/runs/:runId` | monitor loop (read SB workflow status + output) |
| POST | `/api/workflows/:workflowId/run` | dispatch entry — body `{ params, llm?, enabled_roles?, completion_callback? }`, returns `{ run_id }` |
| POST | `/api/clear-markers` | pre-dispatch cleanup (clears stale completion marker) |
| POST | `/api/job-context` | writes `~/.sidebutton/job-context.json` so the Claude Stop hook can attach usage to the right job/step |
| DELETE | `/api/job-context` | clears the same file after the step completes |

Outbound calls:

| Method | Path | When |
|---|---|---|
| POST | `${PORTAL_URL}/api/agents/heartbeat` | every 60s (+ once on startup) |
| POST | `${PORTAL_URL}/api/jobs/step-complete` | when a dispatched claude run exits |

## Workflow dispatch

`POST /api/workflows/<id>/run` spawns
`claude --dangerously-skip-permissions -p -` with the prompt built from
`params.hint` (falling back to a generic prompt mentioning the workflow id +
ticket). Knowledge-pack-aware workflows are out of scope for the bare
variant — by design, this is the smallest surface that lets a bare agent
participate in fleet dispatch end-to-end.

## Env

| Var | Required | Default | Notes |
|---|---|---|---|
| `AGENT_TOKEN` | yes | — | sb_token (or bootstrap token on first heartbeat) |
| `AGENT_NAME` | yes | — | Unique fleet name |
| `PORTAL_URL` | no | `https://sidebutton.com` | Portal base URL |
| `FLEET_CLIENT_PORT` | no | `9876` | Port to listen on |
| `AGENT_RUNNER` | no | `ubuntu-claude-code` | Reported in heartbeat dependency_versions |
| `RUNNERS_REF` | no | `unknown` | Reported in heartbeat dependency_versions |

## Run locally

```bash
AGENT_TOKEN=sb_… AGENT_NAME=my-bare-agent PORTAL_URL=https://sidebutton.com \
  node bin/fleet-job-client.mjs

# from another terminal
curl -s http://localhost:9876/health | jq
```

## Where it's wired in

The `variants/ubuntu-claude-code/` overlay:
- `pre-services.sh` installs `bin/fleet-job-client.mjs` to `/usr/local/` + writes the systemd unit;
- `post-services.sh` enables + starts the unit and waits up to 60s for `/health`.

The shared base steps that install the SB server / knowledge packs / claude
MCP transport short-circuit when `SKIP_SIDEBUTTON_SERVER=1` /
`SKIP_KNOWLEDGE_PACKS=1` are exported (the variant's `early-setup.sh`
sets those).
