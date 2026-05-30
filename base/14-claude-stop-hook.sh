# 14-claude-stop-hook.sh — Claude Code Stop/SubagentStop hook that POSTs
# aggregated token usage + cost to the portal.

step "Step 14/16: Claude stop hook"
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
[ -f "$JOB_CONTEXT" ] || { log "no job-context — skipping"; exit 0; }
JOB_ID=$(jq -r '.job_id // empty' "$JOB_CONTEXT")
STEP_INDEX=$(jq -r '.step_index // empty' "$JOB_CONTEXT")
[ -n "$JOB_ID" ] && [ -n "$STEP_INDEX" ] || { log "incomplete job-context"; exit 0; }
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
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
PAYLOAD=$(jq -n --argjson job_id "$JOB_ID" --argjson step "$STEP_INDEX" \
  --arg sid "$SESSION_ID" --argjson u "$USAGE" \
  --argjson dur "$DURATION_MS" --arg cost "$TOTAL_COST" \
  '{job_id:$job_id, step_index:$step, session_id:$sid,
    usage:($u + {duration_ms:$dur, total_cost_usd_reported:($cost|tonumber)})}')
curl -sf -X POST "${PORTAL_URL}/api/jobs/usage" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$PAYLOAD" --connect-timeout 10 --max-time 30 >/dev/null 2>&1 || true
HOOKEOF
chmod +x "$AGENT_HOME/.local/bin/claude-stop-hook.sh"
