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

# --- PostToolUse attribution forwarder (SCRUM-512) ----------------------------
# Referenced from base/assets/claude-hooks.json (second command on the `.*`
# PostToolUse entry). Forwards one REDUCED event per tool call to
# POST /api/agents/events so the portal can attribute usage per MCP server
# (mcp_tool_calls / mcp_server_stats). tool_input/tool_response can be 100s of
# KB for MCP tools (browser snapshots), so only byte-derived token estimates
# (~4 bytes/token) leave the box — never the raw payloads. TaskCreate/TaskUpdate
# are skipped: the dedicated TaskCreate|TaskUpdate hook entry already posts them
# in full (the task checklist needs tool_input/tool_response). Same job-session
# gate as the liveness marker above; with no job-context session id (operator /
# manual session) the event still posts — production telemetry wants those too.
# The curl runs in the background so a slow portal never adds latency to a tool
# call, and every failure is silent (Claude Code must never see this hook fail).
cat > "$AGENT_HOME/.local/bin/sb-post-tool-event.sh" <<'PTEOF'
#!/usr/bin/env bash
# stdin: Claude Code PostToolUse hook JSON (tool_name, tool_input, tool_response, …).
IN=$(cat 2>/dev/null || true)
[ -z "$IN" ] && exit 0
TOOL=$(echo "$IN" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ -z "$TOOL" ] && exit 0
case "$TOOL" in TaskCreate|TaskUpdate) exit 0 ;; esac
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ]; then
  SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
  if [ -n "$SID" ] && [ "$SID" != "$JOB_SID" ]; then exit 0; fi
fi
[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env"
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
if [ -z "${AGENT_TOKEN:-}" ] || [ -z "${AGENT_NAME:-}" ]; then exit 0; fi
PAYLOAD=$(echo "$IN" | jq -c '{
  session_id: (.session_id // ""),
  tool_name: .tool_name,
  tool_use_id: (.tool_use_id // ("sb-" + (.session_id // "x") + "-" + (now * 1000 | floor | tostring))),
  input_tokens: (((.tool_input // "" | tostring | utf8bytelength) / 4) | round),
  output_tokens: (((.tool_response // "" | tostring | utf8bytelength) / 4) | round),
  duration_ms: (.duration_ms // 0),
  result_status: (if (.tool_response.isError? // .tool_response.is_error? // false) == true then "error" else "ok" end)
}' 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0
curl -4 -sf -X POST "${PORTAL_URL}/api/agents/events" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$PAYLOAD" --connect-timeout 2 --max-time 5 >/dev/null 2>&1 &
exit 0
PTEOF
chmod +x "$AGENT_HOME/.local/bin/sb-post-tool-event.sh"

# --- Stop/SubagentStop hook ---------------------------------------------------
cat > "$AGENT_HOME/.local/bin/claude-stop-hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
# Claude Code Stop/SubagentStop hook — POSTs aggregated usage to portal.
set -euo pipefail
USAGE_LOG="${HOME}/.sidebutton/usage-hook.log"
JOB_CONTEXT="${HOME}/.sidebutton/job-context.json"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$USAGE_LOG" 2>/dev/null || true; }

# --- Phase D git telemetry capture (SCRUM-513) --------------------------------
# At the main Stop, resolve every git repo the agent touched under its workspace
# and emit a `prs` JSON array (one element per repo/PR) onto the step-complete
# payload. All best-effort: any failure → that repo is omitted; the array is at
# worst []. The portal stores it in jobs.prs (final grain, comment 18808) and
# makes NO GitHub calls itself — churn + PR + SHAs all come from the agent's box,
# using its own gh/git credentials. Repos the box can't reach gracefully degrade
# to churn + SHAs with empty PR fields (AC #7).
normalize_repo_url() {
  # git@host:owner/repo(.git) | https://host/owner/repo(.git) -> https://host/owner/repo
  local u="$1"
  [ -z "$u" ] && { echo ""; return 0; }
  u="${u%.git}"
  if [[ "$u" == git@*:* ]]; then
    local host path
    host="${u#git@}"; host="${host%%:*}"
    path="${u#*:}"
    u="https://${host}/${path}"
  fi
  echo "$u"
}
capture_git_prs() {
  set +e
  local entry="$1"
  [ -z "$entry" ] && { echo '[]'; return 0; }
  local -a roots=() uniq=()
  local top sub r u seen
  # entry_path is the WORKSPACE (~/workspace); the repo is a SUBDIR. Resolve the
  # real toplevel for the entry itself and each immediate subdir (≥1 repo), then dedupe.
  if top=$(git -C "$entry" rev-parse --show-toplevel 2>/dev/null); then roots+=("$top"); fi
  for sub in "$entry"/*/; do
    [ -d "$sub" ] || continue
    top=$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null) || continue
    roots+=("$top")
  done
  for r in "${roots[@]}"; do
    seen=0
    for u in "${uniq[@]}"; do [ "$u" = "$r" ] && { seen=1; break; }; done
    [ "$seen" = 0 ] && uniq+=("$r")
  done
  [ ${#uniq[@]} -eq 0 ] && { echo '[]'; return 0; }
  local -a elems=()
  local repo_url sha_end sha_start ss la ld fc co pr_url pr_number state merged_at ghj elem
  for r in "${uniq[@]}"; do
    repo_url=$(normalize_repo_url "$(git -C "$r" remote get-url origin 2>/dev/null)")
    sha_end=$(git -C "$r" rev-parse HEAD 2>/dev/null)
    sha_start=$(git -C "$r" merge-base origin/HEAD HEAD 2>/dev/null)
    [ -z "$sha_start" ] && sha_start=$(git -C "$r" rev-parse HEAD~1 2>/dev/null)
    # churn from the diff range (fallback / non-GitHub hosts)
    la=""; ld=""; fc=""; co=""
    if [ -n "$sha_start" ]; then
      ss=$(git -C "$r" diff --shortstat "${sha_start}...HEAD" 2>/dev/null)
      fc=$(echo "$ss" | grep -oE '[0-9]+ file'      | grep -oE '[0-9]+' | head -1)
      la=$(echo "$ss" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)
      ld=$(echo "$ss" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' | head -1)
      co=$(git -C "$r" rev-list --count "${sha_start}...HEAD" 2>/dev/null)
    fi
    # PR state + authoritative churn from gh (the agent's own token). Empty on no
    # PR / non-GitHub / unreachable — then we keep the git-derived churn above.
    pr_url=""; pr_number=""; state=""; merged_at=""
    ghj=$( (cd "$r" 2>/dev/null && gh pr view --json url,number,state,mergedAt,additions,deletions,changedFiles,commits 2>/dev/null) )
    if [ -n "$ghj" ]; then
      pr_url=$(echo "$ghj"     | jq -r '.url // ""')
      pr_number=$(echo "$ghj"  | jq -r '.number // empty')
      state=$(echo "$ghj"      | jq -r '.state // ""')
      merged_at=$(echo "$ghj"  | jq -r '.mergedAt // ""')
      la=$(echo "$ghj"         | jq -r '.additions // empty')
      ld=$(echo "$ghj"         | jq -r '.deletions // empty')
      fc=$(echo "$ghj"         | jq -r '.changedFiles // empty')
      co=$(echo "$ghj"         | jq -r '(.commits | length) // empty')
    fi
    # Skip a repo we couldn't identify at all (no repo_url AND no pr_url).
    [ -z "$repo_url" ] && [ -z "$pr_url" ] && continue
    elem=$(jq -n \
      --arg repo_url "$repo_url" --arg pr_url "$pr_url" \
      --argjson pr_number "${pr_number:-null}" \
      --arg sha_start "${sha_start:-}" --arg sha_end "${sha_end:-}" \
      --argjson la "${la:-null}" --argjson ld "${ld:-null}" \
      --argjson fc "${fc:-null}" --argjson co "${co:-null}" \
      --arg state "$state" --arg merged_at "$merged_at" \
      '{repo_url:$repo_url, pr_url:$pr_url, pr_number:$pr_number,
        sha_start:$sha_start, sha_end:$sha_end,
        lines_added:$la, lines_deleted:$ld, files_changed:$fc, commits:$co,
        state:$state, pr_merged_at:(if $merged_at=="" then null else $merged_at end)}' 2>/dev/null)
    [ -n "$elem" ] && elems+=("$elem")
  done
  [ ${#elems[@]} -eq 0 ] && { echo '[]'; return 0; }
  printf '%s\n' "${elems[@]}" | jq -s '.' 2>/dev/null || echo '[]'
}

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
  # Phase D (SCRUM-513): resolve the repo(s) under the workspace and attach a `prs`
  # JSON array. entry_path (the workspace) comes from job-context; default ~/workspace.
  # Best-effort — capture_git_prs returns [] on any failure, and [] is dropped below.
  ENTRY_PATH=$(jq -r '.entry_path // empty' "$JOB_CONTEXT" 2>/dev/null || true)
  [ -z "$ENTRY_PATH" ] && ENTRY_PATH="${HOME}/workspace"
  PRS_JSON=$(capture_git_prs "$ENTRY_PATH" 2>/dev/null || echo '[]')
  case "$PRS_JSON" in ''|'[]') PRS_JSON='[]' ;; esac
  log "git telemetry: $(echo "$PRS_JSON" | jq -c 'length') PR(s) from $ENTRY_PATH"
  STEP_COMPLETE_PAYLOAD=$(jq -n --argjson job_id "${JOB_ID:-null}" --argjson step "${STEP_INDEX:-null}" \
    --arg msg "$OUTPUT_MSG" --arg sid "$SESSION_ID" --argjson prs "$PRS_JSON" \
    '{job_id:$job_id, step_index:$step, session_id:$sid, status:"success", output_message:$msg}
      + (if ($prs|length) > 0 then {prs:$prs} else {} end)')
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
