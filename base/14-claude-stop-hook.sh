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

# --- Needs-input request forwarder (SCRUM-1373) -------------------------------
# Referenced from base/assets/claude-hooks.json (PreToolUse + PostToolUse
# AskUserQuestion|ExitPlanMode, the catch-all Notification, and the Stop entry).
# Makes a BLOCKED agent visible in the portal: when Claude blocks on an
# AskUserQuestion / ExitPlanMode prompt, or a permission / idle Notification fires,
# this opens an agent_requests row (POST /api/agents/requests, action=open); the
# matching PostToolUse and the Stop hook resolve it. Same job-session gate as the
# liveness marker / tool-event forwarder so a lingering or operator session can't
# pollute job-attributed signals (with no job-context session id the signal still
# posts — an idle operator box is exactly when "needs you" matters). Only a REDUCED,
# clipped payload leaves the box (question text + option labels / plan / message —
# never raw tool_input). curl is backgrounded + fully silent: Claude Code must never
# see this hook fail, and it must never add latency to a blocking prompt.
cat > "$AGENT_HOME/.local/bin/sb-post-request.sh" <<'PREOF'
#!/usr/bin/env bash
# stdin: Claude Code hook JSON (PreToolUse | PostToolUse | Notification | Stop).
IN=$(cat 2>/dev/null || true)
[ -z "$IN" ] && exit 0
EVENT=$(echo "$IN" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[ -z "$EVENT" ] && exit 0
SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SID" ] && exit 0

# Job-session gate (mirrors sb-mark-tool-use / sb-post-tool-event): while a job
# session is known, a different session's signal is dropped; with none known, post.
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ] && [ "$SID" != "$JOB_SID" ]; then exit 0; fi

TOOL=$(echo "$IN" | jq -r '.tool_name // empty' 2>/dev/null || true)

# Map the firing hook event -> (ACTION, KIND, TUID). Exit for anything we don't capture.
ACTION=""; KIND=""; TUID=""
case "$EVENT" in
  PreToolUse|PostToolUse)
    case "$TOOL" in
      AskUserQuestion) KIND=question ;;
      ExitPlanMode)    KIND=plan ;;
      *) exit 0 ;;
    esac
    if [ "$EVENT" = "PreToolUse" ]; then ACTION=open; else ACTION=resolve; fi
    TUID=$(echo "$IN" | jq -r '.tool_use_id // empty' 2>/dev/null || true)
    [ -z "$TUID" ] && TUID="$TOOL"   # stable fallback so the open/resolve pair still correlates
    ;;
  Notification)
    case "$(echo "$IN" | jq -r '.notification_type // empty' 2>/dev/null || true)" in
      permission_prompt) ACTION=open; KIND=permission; TUID="notif-permission" ;;
      # idle_prompt ("Claude is waiting for your input") is a self-resolving machine state — the
      # portal surfaces idle via the IDLE counter, not the Needs-you band. Capturing it here
      # spammed Needs-you from idle/post-job/between-job sessions, so it falls through to exit 0.
      *) exit 0 ;;   # idle_prompt / auth_success / elicitation_* — not a needs-you state
    esac
    ;;
  Stop)
    ACTION=resolve   # bulk-resolve every open request for this session (no tool_use_id)
    ;;
  *) exit 0 ;;
esac

[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env"
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
if [ -z "${AGENT_TOKEN:-}" ] || [ -z "${AGENT_NAME:-}" ]; then exit 0; fi

if [ "$ACTION" = "open" ]; then
  PAYLOAD=$(echo "$IN" | jq -c --arg sid "$SID" --arg kind "$KIND" --arg tuid "$TUID" '
    def clip($s): ($s // "") | tostring | .[0:2000];
    {
      action: "open", session_id: $sid, tool_use_id: $tuid, kind: $kind,
      payload: (
        if $kind == "question" then
          { questions: [ (.tool_input.questions // [])[] | {
              question: clip(.question),
              options: [ (.options // [])[] | (.label // .) ]
          } ] }
        elif $kind == "plan" then
          { plan: clip(.tool_input.plan // .tool_input.allowedPrompts // "") }
        else
          { message: clip(.message), title: clip(.title) }
        end
      )
    }' 2>/dev/null || true)
elif [ "$EVENT" = "Stop" ]; then
  PAYLOAD=$(jq -nc --arg sid "$SID" '{action:"resolve", session_id:$sid}' 2>/dev/null || true)
else
  PAYLOAD=$(jq -nc --arg sid "$SID" --arg tuid "$TUID" --arg kind "$KIND" \
    '{action:"resolve", session_id:$sid, tool_use_id:$tuid, kind:$kind}' 2>/dev/null || true)
fi
[ -z "$PAYLOAD" ] && exit 0

curl -4 -sf -X POST "${PORTAL_URL}/api/agents/requests" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$PAYLOAD" --connect-timeout 2 --max-time 5 >/dev/null 2>&1 &
exit 0
PREOF
chmod +x "$AGENT_HOME/.local/bin/sb-post-request.sh"

# --- Needs-input answer return (SCRUM-1375) -----------------------------------
# Referenced from base/assets/claude-hooks.json as the SECOND PreToolUse command on
# AskUserQuestion|ExitPlanMode (it runs right after sb-post-request.sh opens the row).
# This is the RETURN half of the loop: it long-polls GET /api/agents/requests/:key for the
# operator's answer (recorded via POST /api/agents/requests/:id/resolve, SCRUM-1374), then maps
# that answer string onto a Claude Code PreToolUse permission decision so the portal pick unblocks
# the run WITHOUT the operator opening the Live desktop.
#
#   plan (ExitPlanMode):  "Keep planning"/reject -> deny (keep planning);  anything else (Approved) -> allow
#   question (AskUserQuestion):  the v2.1.175 hook contract has NO field that injects a tool
#     answer (SCRUM-1375 spike), so the chosen option is delivered through deny + permissionDecisionReason
#     — i.e. the model is STEERED with "Operator selected: '<answer>'" rather than the tool being
#     natively answered. Honoring it is therefore model-dependent (verify in QA).
#
# Strictly gated to THIS job's session (JOB_SID == SID): a manual/operator Claude on the box,
# or any non-job session, exits 0 immediately so its prompts render normally and are never
# blocked. On any miss — no answer within the budget, network error, missing token, the row
# resolved on the desktop instead — it exits 0 with NO output, so the tool proceeds exactly as
# today (AC: free-form / idle / timeout still route to the Live desktop). It NEVER denies on
# uncertainty; a deny is emitted only when a real operator answer says so.
cat > "$AGENT_HOME/.local/bin/sb-await-decision.sh" <<'AWAITEOF'
#!/usr/bin/env bash
# stdin: Claude Code PreToolUse hook JSON (AskUserQuestion | ExitPlanMode).
IN=$(cat 2>/dev/null || true)
[ -z "$IN" ] && exit 0
EVENT=$(echo "$IN" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[ "$EVENT" = "PreToolUse" ] || exit 0
TOOL=$(echo "$IN" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  AskUserQuestion) KIND=question ;;
  ExitPlanMode)    KIND=plan ;;
  *) exit 0 ;;
esac
SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SID" ] && exit 0

# Symmetric with the capture forwarder (sb-post-request.sh): while a job session is known, a
# DIFFERENT session's prompt is left to render normally; with none known (operator/manual session)
# we still serve it — the capture already opened a portal request ungated, so an operator's portal
# pick MUST be able to reach the agent. Previously this skipped whenever no job-context existed,
# which silently dropped every portal answer for operator/manual sessions (the agent never polled).
# The wait budget below is shorter for non-job sessions so an interactive desktop isn't frozen long
# before the prompt falls through to the terminal.
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ] && [ "$SID" != "$JOB_SID" ]; then exit 0; fi

TUID=$(echo "$IN" | jq -r '.tool_use_id // empty' 2>/dev/null || true)
[ -z "$TUID" ] && TUID="$TOOL"          # same stable fallback the capture forwarder uses
KEY="${SID}:${TUID}"

[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env"
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
if [ -z "${AGENT_TOKEN:-}" ] || [ -z "${AGENT_NAME:-}" ]; then exit 0; fi

# Send the request_key RAW. It is session_id:tool_use_id — both URL-safe (UUID + toolu_*), and the
# colon is a legal path char. The portal route matches request_key literally and does NOT %-decode
# the path param, so %-encoding the colon (the previous '$s|@uri' → "%3A") never matched the stored
# key: the agent saw status:pending forever and fell through to the terminal ("declined"). Raw matches.
KEY_ENC="$KEY"
# A portal answer is delivered within ~1s either way (the server returns the moment the row leaves
# 'open'); WAIT_PER/TOTAL only bound the *fallthrough* when nobody answers. Job sessions (operator
# away) poll in long cycles up to a long budget; operator/manual sessions use short cycles + a small
# budget so an interactive desktop isn't frozen — the prompt falls through to the terminal quickly.
if [ -n "$JOB_SID" ] && [ "$SID" = "$JOB_SID" ]; then
  WAIT_PER=25; TOTAL="${SB_REQUEST_WAIT_TOTAL:-100}"          # job: long-poll <= endpoint cap 30
else
  WAIT_PER=8;  TOTAL="${SB_REQUEST_WAIT_TOTAL_OPERATOR:-30}"  # operator: responsive fallthrough
fi
START=$SECONDS

emit() {  # $1=allow|deny  $2=reason
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}' \
    2>/dev/null || true
  exit 0
}

while [ $((SECONDS - START)) -lt "$TOTAL" ]; do
  RESP=$(curl -4 -sf "${PORTAL_URL}/api/agents/requests/${KEY_ENC}?wait=${WAIT_PER}" \
    -H "Authorization: Bearer ${AGENT_TOKEN}" -H "X-Agent-Name: ${AGENT_NAME}" \
    --connect-timeout 5 --max-time $((WAIT_PER + 10)) 2>/dev/null || true)
  [ -z "$RESP" ] && { sleep 1; continue; }        # network blip — retry within the budget

  ANSWER=$(echo "$RESP" | jq -r '.answer // empty' 2>/dev/null || true)
  STATUS=$(echo "$RESP" | jq -r '.status // empty' 2>/dev/null || true)

  if [ -n "$ANSWER" ]; then
    if [ "$KIND" = "plan" ]; then
      # ExitPlanMode: "Keep planning"/reject -> deny (keep planning); anything else (Approved) -> allow.
      case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
        *"keep planning"*|*reject*|*denied*|*deny*) emit deny  "Operator asked to keep planning (${ANSWER}). Do not exit plan mode yet." ;;
        *)                                          emit allow "Plan approved by the operator (${ANSWER})." ;;
      esac
    else
      # question — no native answer field on this Claude Code version (SCRUM-1375 spike), so the
      # operator's pick is delivered as a STEER via deny + reason.
      emit deny "Operator selected: '${ANSWER}'. Proceed with that choice and do not ask again."
    fi
  fi

  # Resolved with no answer = closed on the desktop / by Stop. Stop polling; let it proceed.
  [ "$STATUS" = "resolved" ] && exit 0
  # open / pending — the server already blocked ~${WAIT_PER}s; loop until the budget runs out.
done
exit 0                                             # timeout → no output → tool proceeds (desktop fallback)
AWAITEOF
chmod +x "$AGENT_HOME/.local/bin/sb-await-decision.sh"

# --- Operator steer drain (SCRUM-1378) ----------------------------------------
# Referenced from base/assets/claude-hooks.json as a PostToolUse `.*` command. THE agent-side
# CONSUMER of the steer queue — the missing half of SCRUM-1376. An operator types a free-form hint in
# the Workspace Overview composer (POST /api/agents/:id/steer → agent_steers, stamped with the agent's
# live session_id + a TTL); at the next tool boundary this hook drains GET /api/agents/steer scoped to
# THIS session and feeds the hint(s) to the running Claude as hookSpecificOutput.additionalContext,
# then acks them. No tmux/VNC keystroke injection — it rides Claude Code's native hook-output channel,
# exactly like sb-await-decision.sh returns the operator's ANSWER. PostToolUse fires on every tool
# call, so the portal poll is throttled to once / ~12s via a timestamp file (hint lands at the next
# tool boundary after that window — seconds for a working run). Same job-session gate as the sibling
# PostToolUse hooks. Fully guarded + IPv4: every miss exits 0 with NO stdout so Claude Code is never
# disturbed; only a real hint emits the JSON.
cat > "$AGENT_HOME/.local/bin/sb-drain-steer.sh" <<'STEEREOF'
#!/usr/bin/env bash
# stdin: Claude Code PostToolUse hook JSON (carries the firing session's session_id).
IN=$(cat 2>/dev/null || true)
[ -z "$IN" ] && exit 0
SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SID" ] && exit 0

# Job-session gate (mirrors sb-mark-tool-use / sb-post-tool-event): while a job session is known, a
# different session's tool calls must not drain this job's steer queue. With none known, fall through
# (an operator/manual session steering itself is fine — the hint was enqueued against its own session).
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ] && [ "$SID" != "$JOB_SID" ]; then exit 0; fi

# Throttle: PostToolUse fires on EVERY tool call; hit the portal at most once per ~12s.
TS_FILE="${HOME}/.sidebutton/last-steer-poll"
now=$(date +%s 2>/dev/null || echo 0)
last=$(cat "$TS_FILE" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((now - last)) -lt 12 ] && exit 0
mkdir -p "${HOME}/.sidebutton" 2>/dev/null || true
echo "$now" > "$TS_FILE" 2>/dev/null || true

[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env"
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
if [ -z "${AGENT_TOKEN:-}" ] || [ -z "${AGENT_NAME:-}" ]; then exit 0; fi

# Drain hints scoped to THIS session (fast, no long-poll — must never stall the tool).
RESP=$(curl -4 -sf "${PORTAL_URL}/api/agents/steer?session_id=${SID}" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" -H "X-Agent-Name: ${AGENT_NAME}" \
  --connect-timeout 2 --max-time 5 2>/dev/null || true)
[ -z "$RESP" ] && exit 0

IDS=$(echo "$RESP" | jq -c '[.steers[].id]' 2>/dev/null || echo '[]')
if [ -z "$IDS" ] || [ "$IDS" = "[]" ]; then exit 0; fi

# Compose the steer as additionalContext the model reads on its next turn (ASCII only).
CTX=$(echo "$RESP" | jq -r '
  "Operator steer (live hint from your operator - incorporate into your current work now):\n"
  + ([.steers[].hint] | map("- " + .) | join("\n"))
' 2>/dev/null || true)
[ -z "$CTX" ] && exit 0

# Ack delivered (best-effort, backgrounded — never blocks the tool).
curl -4 -sf -X POST "${PORTAL_URL}/api/agents/steer" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "{\"ack\":${IDS}}" --connect-timeout 2 --max-time 5 >/dev/null 2>&1 &

# Emit to Claude Code (the ONLY stdout this script ever produces).
jq -nc --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}' 2>/dev/null || true
exit 0
STEEREOF
chmod +x "$AGENT_HOME/.local/bin/sb-drain-steer.sh"

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
  entry="${entry/#\~/$HOME}"            # expand a leading ~ — git -C / globs never expand it (SCRUM-513 capture bug)
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
  ENTRY_PATH="${ENTRY_PATH/#\~/$HOME}"   # job-context stores the workspace as "~/workspace"; expand so the log + capture see a real path
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

# Upload gate artifacts (SCRUM-1370). The agent saves deliverables it produces at a playbook gate —
# mockups, QA screenshots, RCA/coverage reports — under <workspace>/artifacts/ (the documented
# contract in the deploy CLAUDE.md); on the final Stop, glob that dir and POST each file to
# /api/jobs/artifacts so the evidence reaches the operator's Files hub + the Run page instead of dying
# on the VM. Gated to the main Stop like the transcript upload (SubagentStop would re-send mid-run).
# The endpoint keys on the session_id query param (v3), falling back to (job_id, step_index), and is
# idempotent per (job, step, filename), so a re-fired Stop overwrites rather than duplicates. Fully
# guarded + IPv4 (cf. #11): any failure here stays invisible to Claude Code. (HOOK_EVENT from above.)
if [ "$HOOK_EVENT" != "SubagentStop" ]; then
  HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  ART_DIR=""
  for d in "${HOOK_CWD:+${HOOK_CWD}/artifacts}" "${HOME}/workspace/artifacts" "${HOME}/artifacts"; do
    if [ -n "$d" ] && [ -d "$d" ]; then ART_DIR="$d"; break; fi
  done
  if [ -n "$ART_DIR" ]; then
    ART_N=0
    ART_MAX=50                      # per-step cap so a runaway dir can't flood the portal
    ART_MAX_BYTES=26214400          # 25 MB — matches the endpoint cap; skip oversized locally
    while IFS= read -r -d '' f; do
      if [ "$ART_N" -ge "$ART_MAX" ]; then log "artifact cap ${ART_MAX} reached — skipping the rest"; break; fi
      FSIZE=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
      if [ "${FSIZE:-0}" -eq 0 ] || [ "${FSIZE:-0}" -gt "$ART_MAX_BYTES" ]; then continue; fi
      FN=$(basename "$f")
      # Infer the gallery kind from the extension (server re-validates against screenshot|mock|report).
      case "$(echo "$FN" | tr '[:upper:]' '[:lower:]')" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp) ART_KIND=screenshot ;;
        *.svg|*.html|*.htm|*.fig)        ART_KIND=mock ;;
        *)                               ART_KIND=report ;;
      esac
      FN_ENC=$(jq -rn --arg s "$FN" '$s|@uri' 2>/dev/null || echo "$FN")
      AR_CODE=$(curl -4 -s -o /dev/null -w '%{http_code}' \
        -X POST "${PORTAL_URL}/api/jobs/artifacts?job_id=${JOB_ID}&step_index=${STEP_INDEX}&session_id=${SESSION_ID}&kind=${ART_KIND}&filename=${FN_ENC}" \
        -H "Content-Type: application/octet-stream" \
        -H "Authorization: Bearer ${AGENT_TOKEN}" \
        -H "X-Agent-Name: ${AGENT_NAME}" \
        --data-binary "@${f}" \
        --connect-timeout 10 --max-time 120) || AR_CODE=0
      ART_N=$((ART_N + 1))
      log "artifact POST ${FN} (${FSIZE}B kind=${ART_KIND}): ${AR_CODE}"
    done < <(find "$ART_DIR" -maxdepth 3 -type f ! -name '.*' -print0 2>/dev/null)
    log "artifacts: posted ${ART_N} file(s) from ${ART_DIR}"
  fi
fi
exit 0
HOOKEOF
chmod +x "$AGENT_HOME/.local/bin/claude-stop-hook.sh"
