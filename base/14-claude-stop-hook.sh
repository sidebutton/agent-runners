# 14-claude-stop-hook.sh — Claude Code Stop/SubagentStop hook that POSTs
# aggregated token usage + cost AND the full session transcript to the portal,
# plus the PostToolUse liveness-marker writer.
#
# CANONICAL agent-side hook. Cloud agents install THIS file (install.sh ->
# base/run.sh); the docs/agents/services/claude-stop-hook.sh copy in the
# the-assistant repo is legacy/manual and is NOT deployed. Any change to the
# portal job-reporting contract — POST /api/jobs/usage, POST /api/jobs/transcript,
# and POST /api/jobs/step-complete (now carrying output_message for the SCRUM-1199
# verdict footer) — MUST land here, or agents silently stop reporting.
# (cf. SCRUM-1166: the transcript upload was added only to the legacy copy, so
#  no cloud agent ever uploaded a session log.)
#
# v3 (JOB-SIGNAL-ATTRIBUTION plan): every Claude session on the box fires these
# hooks, but job identity used to come solely from the box-global
# job-context.json — so a lingering previous session's Stop could complete,
# bill, or overwrite the transcript of the CURRENT job, and a session stopping
# after its own teardown (context already deleted) lost its report entirely
# (jobs 7815 / 7816 / 7824→7827, 2026-06-10). The dispatcher now pre-assigns
# the Claude session UUID (launched via `claude --session-id`, recorded in
# job-context.json AND on job_steps.session_id), and every hook natively
# receives its own session_id on stdin, so:
#   - a session whose stdin session_id differs from job-context's session_id
#     is NOT the job session → skip all portal posts;
#   - posts go through even when job-context.json is already gone — the portal
#     resolves the step by the session_id the hook always sends.
# Old runtime (no pre-assigned id in job-context) => exact legacy behavior.

step "Step 14/16: Claude stop hook"

# --- PostToolUse liveness marker, gated to the job session -------------------
# Referenced from base/assets/claude-hooks.json. last-tool-use feeds stall
# detection and busy/idle classification on the portal — an operator window or
# a lingering previous session must not refresh it while a job runs. With no
# job-context session id (no active job / old runtime) behavior is unchanged.
cat > "$AGENT_HOME/.local/bin/sb-mark-tool-use.sh" <<'TUEOF'
#!/usr/bin/env bash
# stdin: Claude Code hook JSON (carries the firing session's session_id).
IN=$(cat 2>/dev/null || true)
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ]; then
  SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
  if [ -n "$SID" ] && [ "$SID" != "$JOB_SID" ]; then exit 0; fi
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.sidebutton/last-tool-use"
TUEOF
chmod +x "$AGENT_HOME/.local/bin/sb-mark-tool-use.sh"

# --- Stop/SubagentStop hook ---------------------------------------------------
cat > "$AGENT_HOME/.local/bin/claude-stop-hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
# Claude Code Stop/SubagentStop hook — POSTs aggregated usage to portal.
set -euo pipefail
USAGE_LOG="${HOME}/.sidebutton/usage-hook.log"
JOB_CONTEXT="${HOME}/.sidebutton/job-context.json"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$USAGE_LOG" 2>/dev/null || true; }
HOOK_INPUT=$(cat)
[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env"
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
if [ -z "${AGENT_TOKEN:-}" ] || [ -z "${AGENT_NAME:-}" ]; then
  log "missing AGENT_TOKEN/AGENT_NAME — skipping"; exit 0
fi
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')

# Session identity (v3): job-context carries the dispatch-assigned Claude
# session UUID (`claude --session-id`); this hook's stdin carries its own.
# When both are known and differ, this Stop belongs to a lingering previous
# session or an operator window — it must not complete, bill, or overwrite
# the transcript of the current job. No assigned id => legacy behavior.
JOB_SID=$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)
if [ -n "$JOB_SID" ] && [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "$JOB_SID" ]; then
  log "session $SESSION_ID != job session $JOB_SID — skipping portal posts"
  exit 0
fi

# Job identity: the portal resolves the step by the session_id this hook
# always sends, so a missing job-context no longer drops the post — that
# fixes the orphan window between teardown and the next dispatch (job 7816
# shipped PR #572 with zero usage). job_id/step_index ride along as the
# legacy fallback keys when present.
JOB_ID=$(jq -r '.job_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)
STEP_INDEX=$(jq -r '.step_index // empty' "$JOB_CONTEXT" 2>/dev/null || true)
if { [ -z "$JOB_ID" ] || [ -z "$STEP_INDEX" ]; } && [ -z "$SESSION_ID" ]; then
  log "no job-context and no session id — skipping"; exit 0
fi
# SCRUM-1178: only the MAIN agent Stop completes the job. This hook runs on BOTH
# Stop and SubagentStop (usage accumulates on both); SubagentStop fires when a
# sub-agent returns while the main agent is still working, so it must NOT trigger
# completion. final=true only for hook_event_name == "Stop". (Reused below to
# gate the transcript upload too.)
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // empty')
if [ "$HOOK_EVENT" = "Stop" ]; then IS_FINAL=true; else IS_FINAL=false; fi
USAGE='{}'
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  USAGE=$(jq -s '[.[] | select(.type == "assistant" and .message.usage != null)] | {
    input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
    output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
    cache_read_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
    cache_create_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
    turns: length,
    model: (map(.message.model // empty) | last // "")
  }' "$TRANSCRIPT_PATH" 2>/dev/null || echo '{}')
fi
DURATION_MS=$(echo "$HOOK_INPUT" | jq -r '.duration_ms // 0')
TOTAL_COST=$(echo "$HOOK_INPUT" | jq -r '.total_cost_usd // .cost_usd // 0')
PAYLOAD=$(jq -n --argjson job_id "${JOB_ID:-null}" --argjson step "${STEP_INDEX:-null}" \
  --arg sid "$SESSION_ID" --argjson u "$USAGE" \
  --argjson dur "$DURATION_MS" --arg cost "$TOTAL_COST" \
  --argjson final "$IS_FINAL" \
  '{job_id:$job_id, step_index:$step, session_id:$sid, final:$final,
    usage:($u + {duration_ms:$dur, total_cost_usd_reported:($cost|tonumber)})}')
curl -4 -sf -X POST "${PORTAL_URL}/api/jobs/usage" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$PAYLOAD" --connect-timeout 10 --max-time 30 >/dev/null 2>&1 || true
log "posted usage (job ${JOB_ID:-?} step ${STEP_INDEX:-?} session ${SESSION_ID:-?} final=$IS_FINAL)"

# SCRUM-1178 / SCRUM-511: on the main Stop, also POST step-complete — a
# monitor-independent completion path that finalizes the job even if the usage
# POST above failed or the job outlived the Temporal monitor's deadline.
# Idempotent server-side (no-ops once the step is terminal); keyed by the
# session_id (v3), falling back to job_id/step_index server-side.
if [ "$HOOK_EVENT" = "Stop" ]; then
  # SCRUM-1199 (A2): forward the agent's final assistant message as output_message so
  # the portal can parse the ===SB_RESULT=== verdict footer from it (its last line)
  # without re-reading Jira. Last assistant turn's text blocks, joined; "" on any miss.
  OUTPUT_MSG=""
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    OUTPUT_MSG=$(jq -rs '
      ([.[] | select(.type=="assistant")] | last) as $m
      | ($m.message.content // [] | map(select(.type=="text") | .text) | join("\n"))
    ' "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
  fi
  STEP_COMPLETE_PAYLOAD=$(jq -n --argjson job_id "${JOB_ID:-null}" --argjson step "${STEP_INDEX:-null}" \
    --arg msg "$OUTPUT_MSG" --arg sid "$SESSION_ID" \
    '{job_id:$job_id, step_index:$step, session_id:$sid, status:"success", output_message:$msg}')
  curl -4 -sf -X POST "${PORTAL_URL}/api/jobs/step-complete" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AGENT_TOKEN}" \
    -H "X-Agent-Name: ${AGENT_NAME}" \
    -d "$STEP_COMPLETE_PAYLOAD" --connect-timeout 10 --max-time 30 >/dev/null 2>&1 || true
  log "posted step-complete (job ${JOB_ID:-?} step ${STEP_INDEX:-?} session ${SESSION_ID:-?})"
fi

# Upload the full Claude Code session transcript (SCRUM-1166). transcript_path is
# the MAIN session transcript for BOTH Stop and SubagentStop, so gate to the final
# Stop — otherwise every subagent finish re-uploads the same growing file. The
# /api/jobs/transcript endpoint keys by the session_id query param (v3), falling
# back to (job_id, step_index), and overwrites on repeat, so this last read is
# authoritative. Fully guarded + IPv4 (cf. #11): any failure here stays invisible
# to Claude Code. (HOOK_EVENT computed above.)
if [ "$HOOK_EVENT" != "SubagentStop" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  RAW_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  TS_GZ=$(mktemp 2>/dev/null || echo "${HOME}/.sidebutton/transcript-${JOB_ID:-x}-${STEP_INDEX:-x}.gz")
  if gzip -c "$TRANSCRIPT_PATH" > "$TS_GZ" 2>/dev/null; then
    TS_CODE=$(curl -4 -s -o /dev/null -w '%{http_code}' \
      -X POST "${PORTAL_URL}/api/jobs/transcript?job_id=${JOB_ID}&step_index=${STEP_INDEX}&session_id=${SESSION_ID}&bytes=${RAW_BYTES}" \
      -H "Content-Type: application/gzip" \
      -H "Authorization: Bearer ${AGENT_TOKEN}" \
      -H "X-Agent-Name: ${AGENT_NAME}" \
      --data-binary "@${TS_GZ}" \
      --connect-timeout 10 --max-time 120) || TS_CODE=0
    log "transcript POST (${RAW_BYTES}B raw): ${TS_CODE}"
  fi
  rm -f "$TS_GZ"
fi
exit 0
HOOKEOF
chmod +x "$AGENT_HOME/.local/bin/claude-stop-hook.sh"
