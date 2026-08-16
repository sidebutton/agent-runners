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

# --- Pre/PostToolUse marker, gated to the job session ------------------------
# Referenced from base/assets/claude-hooks.json on BOTH the PreToolUse `.*` and
# the PostToolUse `.*` entries. last-tool-use feeds the monitor's regular-workflow
# grace discriminator and idle recovery's recent-activity check on the portal — an
# operator window or a lingering previous session must not refresh it while a job
# runs. With no job-context session id (no active job / old runtime) behavior is
# unchanged. It stays a PostToolUse-only signal: a tool that is about to run has
# not produced activity yet.
cat > "$AGENT_HOME/.local/bin/sb-mark-tool-use.sh" <<'TUEOF'
#!/usr/bin/env bash
# stdin: Claude Code hook JSON (carries the firing session's session_id + hook_event_name).
IN=$(cat 2>/dev/null || true)
# Both fields in ONE jq: this now runs twice per tool call, so a second fork here is a second fork on
# every tool call the agent makes.
SID=""; EVT=""
# One value per LINE, read with two plain `read`s. A @tsv pair read with IFS=$'\t' is WRONG here: tab
# is an IFS *whitespace* character, so a payload with an empty session_id ("\tPreToolUse") has its
# leading empty field collapsed and lands as SID=PreToolUse, EVT="" — which then fails the PreToolUse
# guard below and stamps last-tool-use from the *opening* half of a tool call.
{ read -r SID; read -r EVT; } < <(echo "$IN" | jq -r '.session_id // "", .hook_event_name // ""' 2>/dev/null)
# Belt for a broken/absent jq, which leaves EVT empty and used to let the PRE half fall through to the
# liveness stamp below. Only consulted when jq gave us nothing, so a payload that merely mentions the
# string cannot suppress a real PostToolUse stamp.
if [ -z "$EVT" ]; then
  case "$IN" in *'"hook_event_name"'*'"PreToolUse"'*) EVT="PreToolUse" ;; esac
fi
# --- SCRUM-1973: per-session commit attribution (git telemetry) ---------------
# Bracket every tool call with the git state BEFORE and AFTER it, per repo, keyed by the session's
# OWN id. Two interleaved jobs share ONE checkout and take turns owning HEAD, so the branch the Stop
# hook finds checked out is frequently the neighbour's — and the git capture then attributes the
# neighbour's commits/LOC to this job (in prod: identical aggregates on two different tickets).
#
# The bracket is what makes attribution CAUSAL rather than circumstantial. A sha that changes between
# THIS session's pre and post lines changed *during this session's own tool call*, so those commits
# are this job's. A sha that changes between one tool call's post and the next one's pre changed in
# the gap — that is a neighbour, and it is not attributed here. Sightings alone cannot draw that line:
# a read-only QA job parked on an SE job's branch sees exactly what the SE job sees.
#
# Deliberately BEFORE the job-session gate below, and self-scoped by SID (same reasoning as
# sb-clear-session-stopped.sh): under interleaving job-context names the OTHER job, so gating here
# would blind exactly the session whose attribution we are trying to fix. A per-SID file has no
# cross-session overwrite risk. Pure builtins — no fork, no `git` call — because this fires twice per
# tool call: .git/HEAD is read directly, and only a symbolic ref (a real branch, never a detached
# HEAD) is recorded. Lines are `<repo>\t<branch>\t<sha>\t<pre|post>\t<epoch seconds>`. Measured on a
# 7-repo workspace: ~18ms and ~1.2KB per tool call for both halves together, and the SessionStart
# janitor drops logs older than 7 days. Always exits 0 with no stdout, so the PreToolUse half can
# never block or alter the tool call it precedes.
#
# The TIMESTAMP is what bounds a mid-tool-call arrival (SCRUM-1973 review). Landing on a branch
# inside a tool call says nothing about WHEN the commits on it were made: a neighbour that advanced
# that branch in an earlier gap looks identical to this call having made them. `EPOCHSECONDS` (a bash
# builtin, no fork) lets the reader re-anchor at the newest commit that already existed when this
# call OPENED, so only what appeared during the call itself is attributed.
case "$EVT" in
  PreToolUse)  _kind=pre ;;
  PostToolUse) _kind=post ;;
  *)           _kind="" ;;
esac
if [ -n "$SID" ] && [ -n "$_kind" ]; then
  # Builtin test first so the normal path stays fork-free; a box whose ~/.sidebutton was cleared
  # would otherwise emit a failed-redirect error to stderr once per repo per firing.
  [ -d "${HOME}/.sidebutton" ] || mkdir -p "${HOME}/.sidebutton" 2>/dev/null || true
  # EPOCHSECONDS is a bash-5 builtin. Falling back to 0 on an older bash would stamp every line
  # unusable and silently drop the whole repo to the legacy range, so pay the one fork there instead.
  _now="${EPOCHSECONDS:-}"; [ -n "$_now" ] || _now=$(date +%s 2>/dev/null || echo 0)
  # workspace* so a box with more than one workspace root (~/workspace-2, …) is still bracketed;
  # an unmatched glob just fails the -f test below.
  for _d in "${HOME}"/workspace*/*/ "${HOME}"/workspace*/; do
    _h="${_d%/}/.git/HEAD"
    [ -f "$_h" ] || continue
    read -r _ref < "$_h" 2>/dev/null || continue
    case "$_ref" in
      "ref: refs/heads/"*)
        _sha=""
        [ -f "${_d%/}/.git/${_ref#ref: }" ] && { read -r _sha < "${_d%/}/.git/${_ref#ref: }" 2>/dev/null || _sha=""; }
        # stderr is nulled BEFORE the append, or a failing `>>` reports itself to the real stderr.
        printf '%s\t%s\t%s\t%s\t%s\n' "${_d%/}" "${_ref#ref: refs/heads/}" "$_sha" "$_kind" "$_now" \
          2>/dev/null >> "${HOME}/.sidebutton/session-branches-${SID}.log" || true ;;
    esac
  done
fi
[ "$EVT" = "PreToolUse" ] && exit 0
JOB_SID=$(jq -r '.session_id // empty' "${HOME}/.sidebutton/job-context.json" 2>/dev/null || true)
if [ -n "$JOB_SID" ]; then
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

# --- SessionStart git baseline (SCRUM-1394) -----------------------------------
# Snapshot each workspace repo's HEAD at session start so the Stop hook's git capture can scope to the
# repos THIS session actually advanced — and derive a real sha_start. Without it, capture_git_prs
# emitted EVERY repo with a remote (a planning/QA job inheriting whatever feature branch + already-merged
# PR a prior SE job left checked out on the persistent VM) and collapsed sha_start==sha_end on an
# up-to-date checkout. Referenced from base/assets/claude-hooks.json (SessionStart). Best-effort: any
# miss leaves no baseline file and capture falls back to its legacy behavior, so this is non-regressive.
cat > "$AGENT_HOME/.local/bin/sb-session-start.sh" <<'SESSIONEOF'
#!/usr/bin/env bash
# stdin: Claude Code SessionStart hook JSON (carries this session's session_id + source).
IN=$(cat 2>/dev/null || true)
SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SID" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v jq  >/dev/null 2>&1 || exit 0
JC="${HOME}/.sidebutton/job-context.json"
JOB_SID=$(jq -r '.session_id // empty' "$JC" 2>/dev/null || true)
# SCRUM-1937: stamp the app-editing-session marker. THIS half stays gated to the job session (the
# marker is a single box-global file, so a lingering/operator session must not claim it). job-context
# is guaranteed present at SessionStart (executePipeline writes it before launching claude), whereas
# the boot turn's Stop races the very completion it triggers — and without a marker, every later chat
# turn (the ones with work to save) would fail the autosave gate. Best-effort, no-op for every other
# workflow, and the helper owns the marker's format.
if [ -z "$JOB_SID" ] || [ "$SID" = "$JOB_SID" ]; then
  [ -x "${HOME}/.local/bin/sb-app-autosave.sh" ] \
    && "${HOME}/.local/bin/sb-app-autosave.sh" mark "$SID" </dev/null >/dev/null 2>&1 || true
fi
# SCRUM-1973: the BASELINE below is deliberately NOT gated on job-context. It is written to
# session-heads-<SID>.json — keyed by the session's own id, so there is no overwrite risk that a gate
# could protect against. The gate used to skip it whenever job-context still named an earlier job
# (exactly what happens when a second job's SessionStart races an in-flight one): that session then
# had NO baseline, and capture fell through to `merge-base origin/HEAD HEAD`, claiming every commit
# on whatever branch the shared checkout happened to be on. Writing it unconditionally closes that.
ENTRY=$(jq -r '.entry_path // empty' "$JC" 2>/dev/null || true)
[ -z "$ENTRY" ] && ENTRY="${HOME}/workspace"
ENTRY="${ENTRY/#\~/$HOME}"
mkdir -p "${HOME}/.sidebutton" 2>/dev/null || true
# Janitor: these are per-session files on a persistent VM that runs 12-23 sessions a day, and nothing
# else deletes them. A week is far longer than any session (the tidy timer closes a TUI after 60min).
find "${HOME}/.sidebutton" -maxdepth 1 -type f \
  \( -name 'session-heads-*.json' -o -name 'session-branches-*.log' \) \
  -mtime +7 -delete 2>/dev/null || true
OUT="${HOME}/.sidebutton/session-heads-${SID}.json"
# First SessionStart of a session wins. SessionStart re-fires with the SAME session_id on resume and on
# (auto-)compact; a long SE job that has already committed would then re-snapshot the baseline forward
# onto its own commits, the Stop hook would see HEAD unchanged vs that baseline and DROP the repo —
# regressing the very over-scope fix this writer exists for (SCRUM-1394). Keep the original job-start HEAD.
[ -f "$OUT" ] && exit 0
# Discover repo roots — workspace toplevel + each immediate subdir repo (same set capture_git_prs walks).
roots=()
top=$(git -C "$ENTRY" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && roots+=("$top")
for sub in "$ENTRY"/*/; do
  [ -d "$sub" ] || continue
  top=$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null) || continue
  roots+=("$top")
done
obj='{}'
for r in "${roots[@]}"; do
  sha=$(git -C "$r" rev-parse HEAD 2>/dev/null) || continue
  [ -n "$sha" ] || continue
  obj=$(echo "$obj" | jq -c --arg k "$r" --arg v "$sha" '.[$k]=$v' 2>/dev/null) || obj='{}'
  # SCRUM-1973: record which branches ALREADY EXIST as this session opens. Landing on a branch inside
  # a tool call is ambiguous on its own — `git checkout -b mine && git commit` and `git checkout
  # <a-neighbours-branch>` both show a pre on one branch and a post on another. The difference is
  # that the first branch did not exist a moment ago. Without this list the capture has to refuse
  # every such arrival, which would drop the single most common way an agent starts work.
  # The repo path is prepended by awk, not interpolated into --format, so a `%` anywhere in it cannot
  # be eaten as a format directive.
  git -C "$r" for-each-ref --format='%(refname:short)%09%(objectname)' refs/heads 2>/dev/null \
    | awk -F'\t' -v repo="$r" -v now="${EPOCHSECONDS:-$(date +%s 2>/dev/null || echo 0)}" \
        'NF==2 && $1!="" {print repo"\t"$1"\t"$2"\tstart\t"now}' \
    >> "${HOME}/.sidebutton/session-branches-${SID}.log" 2>/dev/null
done
echo "$obj" > "$OUT" 2>/dev/null || true
exit 0
SESSIONEOF
chmod +x "$AGENT_HOME/.local/bin/sb-session-start.sh"

# --- UserPromptSubmit hook: clear the session-stopped sentinel (SCRUM-1769) ----
# Referenced from base/assets/claude-hooks.json (UserPromptSubmit). The Stop hook
# below marks a finished session (~/.sidebutton/session-stopped/<sid>.json) and
# sb-session-tidy (base/19e) closes its TUI once that mark is older than the TTL.
# A new prompt means the session is working again, so drop the mark: the sweep
# then finds nothing and an actively-engaged session is never closed. The next
# Stop re-writes the sentinel with a fresh stopped_at, so the clock always runs
# from the LAST completion.
#
# Self-scoped to the prompt's OWN session_id, so no job-context gate is needed
# (an operator window clears only its own mark). Best-effort, always exit 0 — a
# prompt submit must never be disturbed by this.
cat > "$AGENT_HOME/.local/bin/sb-clear-session-stopped.sh" <<'CLEAREOF'
#!/usr/bin/env bash
# stdin: Claude Code UserPromptSubmit hook JSON (carries this session's session_id).
IN=$(cat 2>/dev/null || true)
SID=$(echo "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
# Same charset guard as the writer: sid reaches a path here, and it is stdin JSON.
case "${SID:-}" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
rm -f "${HOME}/.sidebutton/session-stopped/${SID}.json" 2>/dev/null || true
exit 0
CLEAREOF
chmod +x "$AGENT_HOME/.local/bin/sb-clear-session-stopped.sh"

# --- Decommission: retired idle-session reaper (SCRUM-1250/SCRUM-1433) ---------
# Job completeness is signalled ONLY by the Stop hook's step-complete POST below;
# the idle-session reaper (former base/19e) and its session-done sentinel
# machinery (writer in this hook, sb-clear-session-done.sh, the UserPromptSubmit
# hook entry) are retired. base/14 is refresh-manifest-listed, so this teardown
# also reaches already-provisioned boxes on their next base refresh. Guarded on
# the artifacts actually existing, so already-clean boxes (and every fresh
# provision) pay two stat() calls instead of systemctl round-trips + a
# daemon-reload on every run.
# TODO (SCRUM-1769): remove this block once the fleet reports no sb-session-reaper
# units. Until then it runs on EVERY refresh, which is why the successor deliberately
# takes different names — sb-session-tidy.* + session-stopped/ + sb-clear-session-stopped.sh
# (this ticket) — so the teardown below cannot delete the replacement it precedes.
# The UserPromptSubmit strip further down is likewise keyed to the retired
# sb-clear-session-done command string, so it leaves the new entry alone.
if [ -e /etc/systemd/system/sb-session-reaper.timer ] || [ -f /opt/sb-session-reaper.sh ]; then
  systemctl disable --now sb-session-reaper.timer >/dev/null 2>&1 || true
  systemctl disable --now sb-session-reaper.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sb-session-reaper.timer \
        /etc/systemd/system/sb-session-reaper.service \
        /opt/sb-session-reaper.sh 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  log "decommissioned retired sb-session-reaper units"
fi
rm -f "$AGENT_HOME/.local/bin/sb-clear-session-done.sh" 2>/dev/null || true
rm -rf "$AGENT_HOME/.sidebutton/session-done" 2>/dev/null || true
# Also strip the retired UserPromptSubmit entry from the LIVE settings directly.
# The hooks re-merge (lib-refresh / agent-redeploy §4b) normally removes it, but
# it runs AFTER this step and is best-effort — if it fails, a hook entry would
# keep pointing at the just-deleted script (exit 127 on every prompt submit).
# Self-contained cleanup removes that ordering coupling. Only OUR entry is
# touched: the key is deleted solely when its commands reference
# sb-clear-session-done; validated tmp + mv so a jq failure never corrupts
# settings.json.
CLAUDE_SETTINGS="$AGENT_HOME/.claude/settings.json"
if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_SETTINGS" ] \
   && jq -e '(.hooks.UserPromptSubmit // []) | tostring | contains("sb-clear-session-done")' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  if jq 'del(.hooks.UserPromptSubmit)' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" 2>/dev/null \
     && jq empty "${CLAUDE_SETTINGS}.tmp" 2>/dev/null; then
    mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
    chown "$AGENT_USER:$AGENT_USER" "$CLAUDE_SETTINGS" 2>/dev/null || true
    log "removed retired UserPromptSubmit hook entry from settings.json"
  else
    rm -f "${CLAUDE_SETTINGS}.tmp" 2>/dev/null || true
  fi
fi

# --- App editing session: per-turn autosave + debounced staged publish (SCRUM-1937) ---
# The durable lane of an `app_edit_session` (SP-D). A live editing session's work exists
# only in this VM's worktree until someone publishes, and the VM is a spot instance —
# a reclaim eats every un-pushed turn. So every turn end now:
#   1. commits the dirty worktree (WIP autosave) so HEAD advances before the Stop hook's
#      capture_git_prs runs and the commit shows up in jobs.prs (SP-J AC #4), and
#      best-effort pushes it to a NAMESPACED SCRATCH REF (sb-autosave/<branch>) — a local
#      commit still dies with the reclaimed spot VM, which is the problem this ticket fixes;
#   2. re-publishes the staged snapshot through the shipped POST /api/agents/landing/publish
#      (SP-H, SCRUM-1940), debounced to ≥60s and detached so a project build never delays
#      the Stop hook's completion POSTs.
#
# WHY A SEPARATE SCRIPT: the Stop hook is `set -euo pipefail` and everything before its
# usage/step-complete POSTs is critical path — an unguarded failure there strands EVERY job
# fleet-wide as `running`. The hook's insert is three guarded lines calling this file; all
# the logic lives here, in a process whose failure the hook cannot even observe. This script
# therefore deliberately does NOT `set -e`/`set -u`: every path must reach `exit 0`, and a
# stray unset var or non-zero step must never abort it.
#
# THE GATE (why job-context alone is not enough): executePipeline clears
# ~/.sidebutton/job-context.json when the session-open job completes — which happens on the
# BOOT turn, the one with nothing to save. The user's chat then continues on the same live
# Claude session with NO job-context at all, so those turns — the ones that actually produce
# work — would never match. Hence a sticky marker (~/.sidebutton/app-session.json) written
# while job-context is still readable, and matched afterwards on the session id:
#
#   job-context present + workflow_id == app_edit_session (+ sid match) → run, (re)write marker
#   job-context present, any other workflow_id                          → never (another job owns the box)
#   job-context absent + marker.session_id == this session (< 24h old)  → run (a chat turn)
#   anything else                                                       → never
#
# The marker is written from BOTH SessionStart (below, where job-context is guaranteed
# present) and the boot turn's Stop, so a job-context cleared early can't silence the whole
# session. Foreign/lingering sessions are already filtered upstream by the hook's own v3
# session gate, and the call site sits inside the `Stop` block so SubagentStop never fires it.
cat > "$AGENT_HOME/.local/bin/sb-app-autosave.sh" <<'APPSAVEEOF'
#!/usr/bin/env bash
# sb-app-autosave.sh — per-turn durability for app editing sessions (SCRUM-1937 / SP-D).
# Installed by agent-runners base/14-claude-stop-hook.sh. See that file for the design notes.
#
#   sb-app-autosave.sh mark <session_id>              # SessionStart: record the marker only
#   sb-app-autosave.sh turn <entry_path> <session_id> # Stop: gate → commit → spawn `defer`
#   sb-app-autosave.sh defer <entry_path> <sid>       # detached: scratch push + debounced publish
#   sb-app-autosave.sh publish <entry_path> <sid>     # the publish half alone (manual / debugging)
#
# NO `set -e`/`set -u` on purpose — see the header in base/14. Always exits 0.

APP_WORKFLOW_ID="app_edit_session"
SB_DIR="${HOME}/.sidebutton"
MARKER="${SB_DIR}/app-session.json"
JOB_CONTEXT="${SB_DIR}/job-context.json"
LOG="${SB_DIR}/app-autosave.log"
BUILD_LOG="${SB_DIR}/app-build.log"
PUBLISH_STAMP="${SB_DIR}/last-app-publish"
PUSH_QUEUE="${SB_DIR}/app-autosave-push-queue"
PUBLISH_LOCK="${SB_DIR}/app-publish.lock"
PUBLISH_PENDING="${SB_DIR}/app-publish-pending"
SCRATCH_NS="sb-autosave"
MARKER_TTL=86400          # a marker older than this is a leftover, not a live session
MIN_PUBLISH_INTERVAL=60   # debounce floor between two staged publishes
MAX_LOCK_AGE=1800         # a publisher holding the lock longer than this is dead
MAX_DIRTY_FILES=2000      # a bigger dirty set means a missing .gitignore, not a turn's work
# The commit half is the ONLY part of this helper on the Stop hook's critical path, and
# base/assets/claude-hooks.json declares no `timeout` for Stop — so Claude Code's 60s default bounds
# the WHOLE hook, and the usage/step-complete POSTs come after us. A single unbounded git call there
# (a huge untracked tree, a cold page cache after a spot resume) would see the hook SIGTERMed and the
# job stranded as `running` fleet-wide. So: every git invocation is individually bounded, AND the
# half as a whole abandons at COMMIT_BUDGET, so N repos cannot stack their way past the budget.
COMMIT_TIMEOUT=10         # ceiling for ONE git invocation
GIT_PROBE_TIMEOUT=5       # ceiling for a cheap probe (rev-parse/symbolic-ref/config)
COMMIT_BUDGET=25          # wall-clock ceiling for the entire synchronous half
PUSH_TIMEOUT=60
BUILD_TIMEOUT=600
PUBLISH_TIMEOUT=180
MAX_RELEASE_FILES=200         # mirrors the-assistant lib/landing/releases.ts
MAX_RELEASE_BYTES=33554432    # 32 MB decoded, ditto

alog() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG" 2>/dev/null || true; }

rotate_log() {
  local sz
  [ -f "$LOG" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
  case "${sz:-}" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -gt 1048576 ] && tail -c 262144 "$LOG" > "${LOG}.rot" 2>/dev/null; then
    mv -f "${LOG}.rot" "$LOG" 2>/dev/null || rm -f "${LOG}.rot" 2>/dev/null
  fi
  return 0
}

run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# --- marker -------------------------------------------------------------------
# started_at_epoch is the SESSION's start and is preserved across rewrites — the TTL must
# bound the session, not be pushed forward by every turn.
write_marker() {
  local sid="$1" entry="$2" prev started now tmp
  mkdir -p "$SB_DIR" 2>/dev/null || return 0
  prev=$(jq -r '.session_id // empty' "$MARKER" 2>/dev/null)
  started=""
  [ "$prev" = "$sid" ] && started=$(jq -r '.started_at_epoch // empty' "$MARKER" 2>/dev/null)
  now=$(date +%s 2>/dev/null || echo 0)
  case "${started:-}" in ''|*[!0-9]*) started="$now" ;; esac
  tmp="${MARKER}.$$.tmp"
  if jq -nc --arg sid "$sid" --arg entry "$entry" --arg wf "$APP_WORKFLOW_ID" \
       --argjson started "$started" --argjson updated "$now" \
       '{session_id:$sid, entry_path:$entry, workflow_id:$wf,
         started_at_epoch:$started, updated_at_epoch:$updated}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$MARKER" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Records the marker when THIS session is an app editing session. Used by `mark` (SessionStart)
# and by the gate below. Returns 1 when job-context says this is not an app session.
mark_if_app_session() {
  local sid="$1" wf jc_sid entry
  [ -n "$sid" ] || return 1
  [ -f "$JOB_CONTEXT" ] || return 1
  wf=$(jq -r '.workflow_id // empty' "$JOB_CONTEXT" 2>/dev/null)
  [ "$wf" = "$APP_WORKFLOW_ID" ] || return 1
  jc_sid=$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null)
  if [ -n "$jc_sid" ] && [ "$jc_sid" != "$sid" ]; then return 1; fi
  entry=$(jq -r '.entry_path // empty' "$JOB_CONTEXT" 2>/dev/null)
  [ -n "$entry" ] || entry="${HOME}/workspace"
  entry="${entry/#\~/$HOME}"
  write_marker "$sid" "$entry"
  GATE_ENTRY="$entry"
  return 0
}

# Sets GATE_ENTRY (the session's project workspace) and returns 0 when this turn belongs to
# a live app editing session. See the gate matrix in base/14.
GATE_ENTRY=""
app_turn_gate() {
  local sid="$1" m_sid m_started now entry
  [ -n "$sid" ] || return 1
  command -v jq  >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  if [ -f "$JOB_CONTEXT" ]; then
    # A job owns the box right now; only the app workflow qualifies. A stale job-context
    # from another workflow deliberately wins over the marker — safety over liveness.
    mark_if_app_session "$sid" && return 0
    return 1
  fi
  [ -f "$MARKER" ] || return 1
  m_sid=$(jq -r '.session_id // empty' "$MARKER" 2>/dev/null)
  [ -n "$m_sid" ] && [ "$m_sid" = "$sid" ] || return 1
  m_started=$(jq -r '.started_at_epoch // 0' "$MARKER" 2>/dev/null)
  case "${m_started:-}" in ''|*[!0-9]*) m_started=0 ;; esac
  now=$(date +%s 2>/dev/null || echo 0)
  if [ "$m_started" -gt 0 ] && [ "$now" -gt "$m_started" ] \
     && [ $((now - m_started)) -gt "$MARKER_TTL" ]; then
    alog "gate: marker for $sid is older than ${MARKER_TTL}s — treating the session as ended"
    return 1
  fi
  entry=$(jq -r '.entry_path // empty' "$MARKER" 2>/dev/null)
  [ -n "$entry" ] || entry="${HOME}/workspace"
  GATE_ENTRY="${entry/#\~/$HOME}"
  return 0
}

# --- commit half (synchronous, runs before capture_git_prs) --------------------
# Same discovery walk as the hook's capture_git_prs: the workspace toplevel plus each
# immediate subdirectory that is a repo.
# Every git call in here is on the Stop hook's critical path, so each one is bounded and the walk
# as a whole stops at CP_DEADLINE. An unbounded `rev-parse` over a workspace of repos is enough on
# its own to blow the hook budget — the probe is cheap in the normal case and must stay cheap in
# every other case too.
cp_expired() {
  [ -n "${CP_DEADLINE:-}" ] || return 1
  [ "$(date +%s 2>/dev/null || echo 0)" -ge "$CP_DEADLINE" ]
}

discover_repos() {
  local entry="$1" top sub
  entry="${entry/#\~/$HOME}"
  [ -d "$entry" ] || return 0
  cp_expired && return 0
  top=$(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$entry" rev-parse --show-toplevel 2>/dev/null) \
    && [ -n "$top" ] && printf '%s\n' "$top"
  for sub in "$entry"/*/; do
    [ -d "$sub" ] || continue
    cp_expired && break
    top=$(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$sub" rev-parse --show-toplevel 2>/dev/null) || continue
    [ -n "$top" ] && printf '%s\n' "$top"
  done
  return 0
}

autosave_commit() {
  local entry="$1" sid="$2" r gitdir branch dirty n msg email secrets deadline now
  local -a ident
  deadline=$(( $(date +%s 2>/dev/null || echo 0) + COMMIT_BUDGET ))
  CP_DEADLINE="$deadline"   # shared with discover_repos, which runs concurrently in the substitution
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -ge "$deadline" ]; then
      alog "commit: ${COMMIT_BUDGET}s critical-path budget spent — stopping here so the completion POSTs still make the hook's deadline"
      break
    fi
    gitdir=$(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$r" rev-parse --git-dir 2>/dev/null) || continue
    case "$gitdir" in /*) ;; *) gitdir="$r/$gitdir" ;; esac
    # Never commit on top of an in-progress operation — `git add -A` would resolve
    # conflict markers into the tree and the user's rebase/merge would be lost.
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] \
       || [ -f "$gitdir/MERGE_HEAD" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ] \
       || [ -f "$gitdir/REVERT_HEAD" ] || [ -f "$gitdir/BISECT_LOG" ]; then
      alog "commit: $r has a git operation in progress — skipped"; continue
    fi
    branch=$(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$r" symbolic-ref --quiet --short HEAD 2>/dev/null)
    if [ -z "$branch" ]; then alog "commit: $r is on a detached HEAD — skipped"; continue; fi
    # Bounded like every other git call here: `status -uall` walks the whole worktree, and on a
    # project whose node_modules/dist are not yet ignored that walk alone can outlive the hook.
    dirty=$(run_timeout "$COMMIT_TIMEOUT" git -C "$r" status --porcelain --untracked-files=all 2>/dev/null)
    [ -n "$dirty" ] || continue
    n=$(printf '%s\n' "$dirty" | grep -c '' 2>/dev/null)
    case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt "$MAX_DIRTY_FILES" ]; then
      alog "commit: $r has $n dirty paths (cap $MAX_DIRTY_FILES) — skipped, likely a missing .gitignore"
      continue
    fi
    # Only supply an identity when the repo/box has none, so a real user identity is kept.
    ident=()
    email=$(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$r" config --get user.email 2>/dev/null)
    if [ -z "$email" ]; then
      ident=(-c "user.name=${AGENT_NAME:-SideButton Agent}" -c "user.email=agent@sidebutton.com")
    fi
    msg="chore(autosave): WIP snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ) [sb-autosave]

Automatic per-turn autosave from a SideButton app editing session (SCRUM-1937).
Not a reviewed change — squash, amend or revert it freely.
session: ${sid}"
    if ! run_timeout "$COMMIT_TIMEOUT" git -C "$r" add -A >/dev/null 2>&1; then
      alog "commit: $r staging failed — left dirty (nothing lost)"; continue
    fi
    # `git add -A` sweeps in everything the project does not ignore, and the detached half force-
    # pushes the result to the repo's own origin — so a `.env` the template never gitignored would
    # land in a real ref on the customer's remote. Anything git does not ALREADY track and that
    # looks like a credential is unstaged again and simply left in the worktree. A secret the repo
    # already tracks is the project's own choice and is never touched.
    secrets=$(run_timeout "$COMMIT_TIMEOUT" git -C "$r" diff --cached --name-only --diff-filter=A 2>/dev/null \
      | grep -Ei '(^|/)(\.env($|\..*)|\.npmrc|\.netrc|id_rsa|id_ed25519|.*\.pem|.*\.p12|.*\.pfx|.*\.keystore|secrets?\.(json|ya?ml|txt))$' 2>/dev/null)
    if [ -n "$secrets" ]; then
      while IFS= read -r s; do
        [ -n "$s" ] && run_timeout "$COMMIT_TIMEOUT" git -C "$r" reset -q -- "$s" >/dev/null 2>&1
      done <<< "$secrets"
      alog "commit: $r excluded $(printf '%s\n' "$secrets" | grep -c '') untracked secret-like path(s) from the snapshot"
    fi
    if run_timeout "$GIT_PROBE_TIMEOUT" git -C "$r" diff --cached --quiet 2>/dev/null; then
      alog "commit: $r had nothing left to snapshot after the secret exclusion — skipped"; continue
    fi
    # --no-verify is deliberate. The project's own pre-commit/commit-msg hooks (husky + lint-staged
    # is the norm in exactly the scaffolded projects this lane serves) would otherwise run ON THE
    # STOP HOOK'S CRITICAL PATH: a lint error on half-finished WIP would fail every commit and
    # silently disable durability for the whole session, and a slow formatter would eat the hook
    # budget. An autosave snapshot is not a reviewed commit and must never be gated on one.
    if run_timeout "$COMMIT_TIMEOUT" git -C "$r" "${ident[@]}" commit -q --no-verify -m "$msg" >/dev/null 2>&1; then
      alog "commit: $r $branch +${n} path(s) → $(run_timeout "$GIT_PROBE_TIMEOUT" git -C "$r" rev-parse --short HEAD 2>/dev/null)"
    else
      alog "commit: $r commit failed — left dirty (nothing lost)"; continue
    fi
    # The push is NOT done here. This half runs on the Stop hook's critical path, inside
    # Claude Code's 60s hook budget, ahead of the only POSTs that mark the job complete —
    # so it must stay local and fast. The repo is queued for the detached half instead.
    printf '%s\n' "$r" >> "$PUSH_QUEUE" 2>/dev/null || true
  done < <(discover_repos "$entry" | sort -u)
  return 0
}

# Detached half, step 1: mirror each freshly autosaved repo to a NAMESPACED SCRATCH REF.
# A commit that never leaves the box still dies with the reclaimed spot VM, which is the
# problem this ticket exists to fix. The target is never the real branch, so the --force
# cannot rewrite anything the user or the agent pushed themselves.
drain_push_queue() {
  local q r branch
  [ -s "$PUSH_QUEUE" ] || return 0
  q="${PUSH_QUEUE}.$$"
  mv -f "$PUSH_QUEUE" "$q" 2>/dev/null || return 0
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    git -C "$r" remote get-url origin >/dev/null 2>&1 || continue
    branch=$(git -C "$r" symbolic-ref --quiet --short HEAD 2>/dev/null)
    [ -n "$branch" ] || continue
    if run_timeout "$PUSH_TIMEOUT" git -C "$r" push --force --quiet origin \
         "HEAD:refs/heads/${SCRATCH_NS}/${branch}" >/dev/null 2>&1; then
      alog "push: $r → origin ${SCRATCH_NS}/${branch}"
    else
      # Re-queue: the queue is destructive-on-read, so without this a single transient failure
      # (network blip, expired credential, a 5xx, PUSH_TIMEOUT on a big first push) would strand
      # that commit on the box forever — it would only be retried if a LATER turn happened to
      # produce another commit, and a reclaim after the session's last turn is precisely the case
      # this feature exists to survive.
      alog "push: scratch push failed for $r — re-queued for the next turn (VM-local for now)"
      printf '%s\n' "$r" >> "$PUSH_QUEUE" 2>/dev/null || true
    fi
  done < <(sort -u "$q" 2>/dev/null)
  rm -f "$q" 2>/dev/null
  return 0
}

# --- publish half (detached, debounced) ----------------------------------------
# The project is the workspace itself when it holds a package.json, otherwise the single
# project directory inside it. A kit-derived project (one carrying the landing publish
# client) always wins, since that is the one we know how to ship.
resolve_project() {
  local entry="$1" d best="" n=0
  entry="${entry/#\~/$HOME}"
  if [ -f "$entry/package.json" ]; then printf '%s\n' "$entry"; return 0; fi
  for d in "$entry"/*/; do
    d="${d%/}"
    [ -f "$d/package.json" ] || continue
    n=$((n + 1))
    if is_kit_client "$d/scripts/publish.mjs"; then printf '%s\n' "$d"; return 0; fi
    [ -z "$best" ] && best="$d"
  done
  [ "$n" -eq 1 ] && { printf '%s\n' "$best"; return 0; }
  return 1
}

# A `scripts/publish.mjs` is only OUR landing-kit client if it actually talks to the publish
# endpoint — this script must never execute an unrelated file that happens to share the name.
is_kit_client() {
  [ -f "$1" ] && grep -q 'api/agents/landing/publish' "$1" 2>/dev/null
}

# Does this project ship through git? (SCRUM-1965 / SP2-C)
#
# An origin remote is the whole test. A repo project's durable lane IS git — the v2 session contract
# ends every turn with a commit pushed to the project's branch — so republishing it to the landing
# floor as well would mint a SECOND durable copy: an `lp-<name>` site the user never asked for,
# silently competing with their own repo for "where did my work go", and re-publishing whatever the
# turn happened to leave in dist/. `git -C` walks up from the app directory, so a monorepo app whose
# checkout root is a level or two above still answers correctly here.
#
# A project with NO remote (the Phase-1 landing-kit lane) is unaffected and keeps auto-republishing.
# The scratch-ref push in drain_push_queue is likewise unaffected: it targets a namespaced ref rather
# than a site, and it is the safety net for a commit that has not been pushed yet.
has_origin_remote() {
  run_timeout "$GIT_PROBE_TIMEOUT" git -C "$1" remote get-url origin >/dev/null 2>&1
}

# Fallback for a project without the kit client: POST dist/ as-is. Deliberately strict —
# it publishes only a bundle whose root is already the site root, and only with an explicit
# slug, because guessing either would ship a broken release.
generic_publish() {
  local proj="$1" dist slug f rel ext sz b64 n=0 bytes=0 code unchanged skipped=0 skipped_eg=""
  local files_tmp payload resp
  dist=""
  for f in "$proj/dist" "$proj/build"; do [ -d "$f" ] && { dist="$f"; break; }; done
  [ -n "$dist" ] || { alog "publish: no dist/ or build/ in $proj — skipped"; return 0; }
  slug="${LANDING_SLUG:-}"
  [ -n "$slug" ] || { alog "publish: no landing kit client and no LANDING_SLUG — skipped"; return 0; }
  [ -f "$dist/index.html" ] || { alog "publish: $dist has no index.html at its root — skipped"; return 0; }
  command -v base64 >/dev/null 2>&1 || { alog "publish: base64 missing — skipped"; return 0; }
  files_tmp="${SB_DIR}/.app-publish-files.$$"
  payload="${SB_DIR}/.app-publish-payload.$$"
  resp="${SB_DIR}/.app-publish-resp.$$"
  : > "$files_tmp" 2>/dev/null || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"$dist"/}"
    if [ "${#rel}" -gt 200 ]; then
      skipped=$((skipped + 1)); skipped_eg="${skipped_eg:-$rel}"; continue
    fi
    ext=$(printf '%s' "${rel##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
      html|css|js|mjs|svg|png|jpg|jpeg|webp|ico|txt|xml|woff2|webmanifest) ;;
      # The server's allowlist is closed, so a dist/ carrying .json data, .ttf/.woff fonts, .gif or
      # .avif publishes WITHOUT them and answers 200 — a green publish over a site that 404s its own
      # assets. We cannot ship them, but a silent drop is undiagnosable: name them in the log.
      *) skipped=$((skipped + 1)); skipped_eg="${skipped_eg:-$rel}"; continue ;;
    esac
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); case "${sz:-}" in ''|*[!0-9]*) sz=0 ;; esac
    n=$((n + 1)); bytes=$((bytes + sz))
    if [ "$n" -gt "$MAX_RELEASE_FILES" ] || [ "$bytes" -gt "$MAX_RELEASE_BYTES" ]; then
      alog "publish: $dist exceeds the release caps (files>${MAX_RELEASE_FILES} or bytes>${MAX_RELEASE_BYTES}) — skipped"
      rm -f "$files_tmp"; return 0
    fi
    b64=$(base64 -w0 "$f" 2>/dev/null) || continue
    jq -nc --arg p "$rel" --arg c "$b64" '{path:$p, content_b64:$c}' >> "$files_tmp" 2>/dev/null || true
  done < <(find "$dist" -type f ! -name '.*' -print0 2>/dev/null)
  if [ "$n" -eq 0 ] || ! jq -s --arg slug "$slug" '{slug:$slug, files:.}' "$files_tmp" > "$payload" 2>/dev/null; then
    alog "publish: could not build a payload from $dist — skipped"
    rm -f "$files_tmp" "$payload"; return 0
  fi
  code=$(curl -4 -s -o "$resp" -w '%{http_code}' -X POST "${PORTAL_URL}/api/agents/landing/publish" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${AGENT_TOKEN}" \
    --data-binary "@${payload}" --connect-timeout 10 --max-time "$PUBLISH_TIMEOUT" 2>/dev/null) || code=0
  # SP-H (SCRUM-1940): `unchanged` — not a moved release_ts — is what says whether this
  # publish wrote anything. A 422 here is the intended answer for a staged bundle posted
  # after go-live: log it and drop it, never retry.
  # `// empty` would be wrong here: jq treats `false` as absent, and false is exactly the
  # answer that means "a release WAS written" (SP-H). Distinguish it from a missing field.
  unchanged=$(jq -r 'if has("unchanged") then (.unchanged|tostring) else "absent" end' "$resp" 2>/dev/null)
  alog "publish: generic POST slug=${slug} files=${n} bytes=${bytes} http=${code:-0} unchanged=${unchanged:-?}"
  [ "$skipped" -gt 0 ] && alog "publish: WARNING ${skipped} file(s) in $dist were NOT published (unsupported extension or path >200 chars), e.g. ${skipped_eg} — the staged site will 404 on them"
  case "${code:-0}" in
    2*) ;;
    *) alog "publish: response $(head -c 400 "$resp" 2>/dev/null | tr '\n' ' ')" ;;
  esac
  rm -f "$files_tmp" "$payload" "$resp"
  return 0
}

# Release the publish lock, but ONLY if we still own it. A stale-lock breaker may have handed the
# lock to another publisher while we were still running (a hung build when `timeout` is absent, or
# an operator setting SB_APP_PUBLISH_MIN_INTERVAL above MAX_LOCK_AGE); an unconditional rmdir would
# then delete THEIR lock and let two builds + POSTs race in the same project, publishing the site
# from a half-written dist/.
LOCK_TOKEN=""
release_lock() {
  [ -n "$LOCK_TOKEN" ] || return 0
  [ "$(cat "${PUBLISH_LOCK}/owner" 2>/dev/null)" = "$LOCK_TOKEN" ] || return 0
  rm -rf "$PUBLISH_LOCK" 2>/dev/null || true
  LOCK_TOKEN=""
  return 0
}

publish_staged() {
  local entry="$1" sid="$2" age rounds=0
  mkdir -p "$SB_DIR" 2>/dev/null || return 0
  # A publisher that died mid-flight (spot reclaim, OOM) must not silence the lane forever.
  if [ -d "$PUBLISH_LOCK" ]; then
    age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$PUBLISH_LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -gt "$MAX_LOCK_AGE" ]; then
      rm -rf "$PUBLISH_LOCK" 2>/dev/null && alog "publish: broke a stale lock (${age}s old)"
    fi
  fi
  # Single-flight. A turn that cannot take the lock RECORDS that the tree moved after the current
  # publisher last read it, and the holder drains that flag below. Coalescing by dropping the turn
  # outright is only safe while the holder is still sleeping out its debounce — once it has started
  # building or POSTing it has already read the tree, so those edits would never be published. The
  # last turn of a session is exactly when that silently loses the user's final work.
  if ! mkdir "$PUBLISH_LOCK" 2>/dev/null; then
    : > "$PUBLISH_PENDING" 2>/dev/null || true
    alog "publish: a publish is already running — flagged it for a trailing pass"
    return 0
  fi
  LOCK_TOKEN="$$-$(date +%s 2>/dev/null || echo 0)"
  echo "$LOCK_TOKEN" > "${PUBLISH_LOCK}/owner" 2>/dev/null || true
  trap 'release_lock' EXIT INT TERM
  rm -f "$PUBLISH_PENDING" 2>/dev/null || true
  publish_once "$entry" "$sid"
  # Drain anything that landed while we were building/POSTing. Bounded, and each pass re-enters the
  # debounce, so a busy session cannot spin here.
  while [ -f "$PUBLISH_PENDING" ] && [ "$rounds" -lt 3 ]; do
    rm -f "$PUBLISH_PENDING" 2>/dev/null || true
    rounds=$((rounds + 1))
    alog "publish: a turn landed mid-publish — trailing pass ${rounds}"
    publish_once "$entry" "$sid"
  done
  release_lock
  trap - EXIT INT TERM
  return 0
}

publish_once() {
  local entry="$1" sid="$2" proj last now wait rc out
  last=$(cat "$PUBLISH_STAMP" 2>/dev/null); case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s 2>/dev/null || echo 0)
  wait=$(( MIN_PUBLISH_INTERVAL - (now - last) ))
  [ "$wait" -gt "$MIN_PUBLISH_INTERVAL" ] && wait="$MIN_PUBLISH_INTERVAL"   # clock jumped backwards
  if [ "$wait" -gt 0 ]; then
    alog "publish: debouncing ${wait}s before the trailing publish"
    sleep "$wait"
  fi
  if [ -z "${AGENT_TOKEN:-}" ]; then alog "publish: no agent token — skipped"; return 0; fi
  proj=$(resolve_project "$entry") || proj=""
  if [ -z "$proj" ]; then alog "publish: no single project under $entry — skipped"; return 0; fi
  # Skip BEFORE the debounce stamp and the build: a repo project must cost nothing here, and a stamp
  # written for a publish that never happens would delay a real one if the project later loses its
  # remote. Deliberately not a debounce-worthy event — it is a permanent property of the project.
  if has_origin_remote "$proj"; then
    alog "publish: $proj has an origin remote — its durable lane is git (turn end = commit + push), floor publish skipped"
    return 0
  fi
  # Stamp BEFORE the work: an attempt has started, and the floor is the spacing between
  # attempts. A build that outruns the interval must not make the next turn publish instantly.
  date +%s > "$PUBLISH_STAMP" 2>/dev/null || true
  if command -v npm >/dev/null 2>&1 && jq -e '.scripts.build' "$proj/package.json" >/dev/null 2>&1; then
    if ( cd "$proj" && run_timeout "$BUILD_TIMEOUT" npm run build ) > "$BUILD_LOG" 2>&1; then
      alog "publish: built $proj"
    else
      alog "publish: build failed in $proj (see ${BUILD_LOG}) — skipping the publish"
      return 0
    fi
  fi
  if is_kit_client "$proj/scripts/publish.mjs" && command -v node >/dev/null 2>&1; then
    out=$( cd "$proj" && run_timeout "$PUBLISH_TIMEOUT" node scripts/publish.mjs 2>&1 ); rc=$?
    alog "publish: kit client rc=${rc} :: $(printf '%s' "$out" | tr '\n' ' ' | tail -c 400)"
  else
    generic_publish "$proj"
  fi
  return 0
}

# --- entry point ---------------------------------------------------------------
mkdir -p "$SB_DIR" 2>/dev/null || true
rotate_log
[ -f "${HOME}/.agent-env" ] && . "${HOME}/.agent-env" 2>/dev/null
AGENT_TOKEN="${AGENT_TOKEN:-${SIDEBUTTON_AGENT_TOKEN:-}}"
AGENT_NAME="${AGENT_NAME:-${SIDEBUTTON_AGENT_NAME:-}}"
PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
# Operator controls, read AFTER ~/.agent-env so a single line in that file tunes or kills the
# lane on a box (or fleet-wide via the secrets step) without waiting for a base refresh.
case "${SB_APP_AUTOSAVE_DISABLE:-0}" in
  1|true|yes|on) alog "disabled via SB_APP_AUTOSAVE_DISABLE — nothing to do"; exit 0 ;;
esac
case "${SB_APP_PUBLISH_MIN_INTERVAL:-}" in
  ''|*[!0-9]*) ;;
  *) MIN_PUBLISH_INTERVAL="$SB_APP_PUBLISH_MIN_INTERVAL" ;;
esac
# `turn` re-execs this file detached, so $0 must survive an inherited cwd change.
SELF="$0"
case "$SELF" in
  /*) ;;
  *)  SELF="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/$(basename "$SELF")" ;;
esac
MODE="${1:-}"
case "$MODE" in
  mark)
    command -v jq >/dev/null 2>&1 || exit 0
    mark_if_app_session "${2:-}" && alog "marked app session ${2:-} (entry=${GATE_ENTRY})"
    ;;
  turn)
    app_turn_gate "${3:-}" || exit 0
    alog "turn: app session ${3:-} entry=${GATE_ENTRY}"
    autosave_commit "$GATE_ENTRY" "${3:-}"
    # Everything with a network or a build in it is detached, so nothing sits between the
    # agent finishing and the portal learning the step completed. </dev/null + full
    # redirection keeps Claude Code from waiting on an inherited pipe.
    if command -v setsid >/dev/null 2>&1; then
      setsid "$SELF" defer "$GATE_ENTRY" "${3:-}" </dev/null >/dev/null 2>&1 &
    else
      nohup "$SELF" defer "$GATE_ENTRY" "${3:-}" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    ;;
  defer)
    # The push runs BEFORE the single-flight publish lock: a turn whose publish is
    # coalesced into a pending one must still get its commit off the box.
    drain_push_queue
    publish_staged "${2:-}" "${3:-}"
    ;;
  publish)
    publish_staged "${2:-}" "${3:-}"
    ;;
  *)
    alog "unknown mode '${MODE}' — nothing to do"
    ;;
esac
exit 0
APPSAVEEOF
chmod +x "$AGENT_HOME/.local/bin/sb-app-autosave.sh"

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
# Which remote ref does this repo's current branch publish to? (SCRUM-1965 / SP2-C)
#
# The v2 session contract ends every turn with a commit pushed to the project's branch, and the
# portal's turn stamp has to say whether that push landed. It answers OFFLINE, from the
# remote-tracking ref: the agent's own `git push` fast-forwards it, and a rejected push leaves it
# behind — so `<upstream>..HEAD` is an exact, network-free count of commits that exist only locally.
# No fetch, no gh call: this runs on the critical path in front of the completion POST.
#
# Configured @{upstream} first (what push actually targets), then origin/<branch> for a branch that
# was never `-u`-tracked but does have a remote counterpart. Neither => no answer at all, and the
# caller emits nulls rather than guessing: a detached HEAD or a never-pushed branch is unknown, NOT
# unpushed, and the portal renders unknown as silence.
# $2 = the job's own branch (SCRUM-1973). Empty => the checked-out branch (legacy).
upstream_ref() {
  local r="$1" br="${2:-}" up
  if [ -z "$br" ]; then
    up=$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    [ -n "$up" ] && { echo "$up"; return 0; }
    br=$(git -C "$r" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  else
    up=$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name "${br}@{upstream}" 2>/dev/null)
    [ -n "$up" ] && { echo "$up"; return 0; }
  fi
  [ -n "$br" ] || return 1
  git -C "$r" rev-parse --verify --quiet "refs/remotes/origin/${br}" >/dev/null 2>&1 || return 1
  echo "origin/${br}"
}
# Which branches did THIS job actually advance, best candidate first? (SCRUM-1973)
#
# The checked-out branch is NOT the answer on a shared checkout: with two jobs interleaved on one
# agent workspace, whichever job's Stop fires second finds its neighbour's branch under HEAD. Nor is
# "the branch this session was seen on most" — a read-only QA job parked on an SE job's branch is
# seen on it constantly, and a job that spends its session reading before cutting its branch is seen
# on the default branch far more than on its own.
#
# The pre/post bracket the marker hook writes makes it decidable. A branch whose sha moved BETWEEN a
# pre line and its own post line moved during one of this session's tool calls, so those commits are
# this job's; a sha that moved between a post and the next pre moved in the gap, which is a
# neighbour. Candidates are exactly the branches with at least one such advancing transition, ranked
# by how many, then by which happened last. `start` is the pre-sha of a branch's FIRST advancing
# transition — this job's true starting point, even when it cut the branch and committed inside a
# single tool call (`git checkout -b x && git commit`), where nothing else can supply an anchor.
#
# Emits `<branch>\t<start sha>` per line. Exit 1 when the log is missing or carries no usable pair
# for this repo (old box, hooks not yet deployed, or a packed ref the builtins-only writer cannot
# read) — the caller then keeps the pre-SCRUM-1973 behaviour rather than reporting a false zero.
#
# Residual: a neighbour committing DURING one of this session's own tool calls still lands inside the
# bracket, whether it commits to a branch this session already knew about or one it cuts on the spot.
# The window is the execution of a single tool call rather than the whole session, and the Stop-time
# autosave adds a second window one `git add && git commit` long — a large reduction, not an
# elimination. What is bounded is the magnitude: an arrival is anchored at a sha this session itself
# observed, so even a mis-attributed commit can never drag in a branch's earlier history.
job_branch_candidates() {
  local r="$1" sid="${2:-}" log="" raw=""
  [ -n "$sid" ] || return 1
  log="${HOME}/.sidebutton/session-branches-${sid}.log"
  [ -f "$log" ] || return 1
  raw=$(awk -F'\t' -v repo="$r" '
        $1!=repo || $2=="" { next }
        # A marker line with no sha means the writer could not read that ref with its builtins —
        # packed refs (what `git gc --auto` leaves behind) or a worktree whose .git is a file. Even
        # ONE such line makes the bracket unreliable for this repo: `git gc` mid-session packs the
        # old refs while a branch cut afterwards stays loose, so the readable half looks complete
        # while the anchors it needs are missing. Refuse the whole repo rather than report a zero.
        $3=="" { if ($4=="pre" || $4=="post") blind++; next }
        # A bracket line written by a pre-review marker carries no timestamp. Without one an arrival
        # cannot be bounded (see the anchor rules below), so treat the repo the same way as a blind
        # line: refuse it and let the caller keep the legacy range. Only ever true for a session that
        # spans the roll-out of this change.
        $4!="start" && $5=="" { notime++; next }
        # Branches that existed as the session opened, with the sha each had then. That sha is this
        # session own opening view of the branch, which makes it a safe anchor: it cannot reach back
        # into work a previous job did on the same branch.
        $4=="start" { existed[$2]=1; startsha[$2]=$3; have_start=1; next }
        # Pending state is kept PER BRANCH, and a post only ever compares against a pre of its OWN
        # branch. Comparing across branches turns any checkout inside a tool call into a fabricated
        # advance anchored at the branch you came from — `git checkout <neighbour-branch>` would
        # claim that whole branch, and a follow-up job would re-report the earlier job work.
        #
        # `seen` counts ONLY lines the marker hook itself wrote. The git-written start and
        # session-bracket lines always carry a real sha, so counting them would mask exactly the
        # case that must fall back to the legacy path: a repo whose marker lines are all empty-sha
        # because the writer could not read the ref (packed refs, or a worktree where .git is a
        # file). Reporting zero there is a false zero, not an observation.
        $4=="pre"  { seen++; pending[$2]=$3; ptime[$2]=$5; last_pre=$3; last_pre_t=$5; next }
        $4=="spre" {         pending[$2]=$3; ptime[$2]=$5; last_pre=$3; last_pre_t=$5; next }
        $4=="post" || $4=="spost" {
          if ($4=="post") seen++
          if ($2 in pending) {
            if (pending[$2] != $3) {
              adv[$2]++; last[$2]=NR
              if (!($2 in start)) { start[$2]=pending[$2]; stime[$2]=ptime[$2] }
            }
            # Advance the anchor to what we just observed rather than clearing it: Claude Code
            # batches independent tool calls, so brackets interleave (pre A, pre B, post B, post A).
            # Clearing on the first post left the last post of a batch with no anchor at all, and
            # the work done by that call vanished from the report.
            pending[$2]=$3
          } else if (have_start) {
            # Landed on a branch with no pre of its own, so the checkout happened inside this tool
            # call. This is `git checkout -b x && git commit`, the most common way work starts, and
            # dropping it outright would report zero for a whole class of real jobs.
            #
            # But WHICH branch was arrived at cannot tell us who made the commits on it: a branch a
            # neighbour advanced during an earlier gap looks exactly like one this call built. A sha
            # anchor alone therefore over-claims — anchoring at the session-open sha hands this job
            # every commit a neighbour made on that branch since the session opened, which is the
            # very cross-attribution this ticket exists to close. So the anchor is a sha AND the
            # time this tool call OPENED (`last_pre_t`): the caller re-anchors at the newest commit
            # that already existed at that instant, so only what appeared during this call counts.
            # Flagged cross-branch so the caller applies that bound and never falls back to the
            # branch creation point, which is unbounded.
            anchor = ($2 in existed) ? startsha[$2] : last_pre
            if (anchor != "" && $3 != anchor && last_pre_t != "" && last_pre_t+0 > 0) {
              adv[$2]++; last[$2]=NR
              if (!($2 in start)) { start[$2]=anchor; stime[$2]=last_pre_t; cross[$2]=1 }
            }
            pending[$2]=$3
          } else {
            # An arrival in a repo with no session-open branch list — the repo was cloned or added
            # to the workspace mid-session. There is nothing to anchor against, and staying silent
            # here made awk exit 0 with no candidates, which the caller reads as the truthful "this
            # job committed nothing" answer and drops the repo. That LOSES the work this job did,
            # where the legacy range would have reported it. Refuse the repo instead.
            # (No apostrophes anywhere in this awk body — it is inside a single-quoted program.)
            unresolved++
            pending[$2]=$3
          }
          next
        }
        END {
          # No marker line at all, or any unreadable/unanchorable one => no trustworthy data, which
          # is NOT evidence of idleness. Say so with a non-zero exit so the caller falls back to the
          # legacy range instead of reporting a false zero and losing real work outright.
          if (seen == 0 || blind > 0 || notime > 0 || unresolved > 0) exit 1
          # cross first so a branch this session was genuinely ON always outranks one it merely
          # landed on; then advance count, then recency.
          for (k in adv) printf "%d\t%d\t%d\t%s\t%s\t%d\n", \
            (k in cross ? 1 : 0), adv[k], last[k], k, start[k], (stime[k]+0)
        }
      ' "$log" 2>/dev/null) || return 1
  # Usable data but nothing advanced: succeed with NO output. That is the "this job committed
  # nothing of its own" answer, and it must not be confused with the no-data exit above — piping
  # awk straight into sort would have masked its status behind cut's.
  [ -n "$raw" ] || return 0
  # Emits `<cross>\t<branch>\t<anchor sha>\t<anchor epoch>` per line, best candidate first.
  printf '%s\n' "$raw" | sort -k1,1n -k2,2nr -k3,3nr | cut -f1,4,5,6
}
# Where did this job's work on <branch> begin? (SCRUM-1973)
#   $3 = this session's HEAD baseline, $4 = the sha the branch had when this session FIRST saw it.
#
# Three anchors, and the LATEST one (the descendant) is right — each alone is a live bug:
#   - first sighting. The most precise: it is this session's own view of the branch before it worked
#     on it. Required when the job branched off the NEIGHBOUR's tip, where the session baseline is
#     the pre-work SHA both jobs share and baseline..head swallows the neighbour's commits whole.
#   - branch creation point (oldest reflog entry for the ref = the SHA the branch was cut from) —
#     the fallback when the log carries no sha (a packed ref the builtins-only writer cannot read).
#   - this session's HEAD baseline. Covers a follow-up job resuming an EXISTING branch, where the
#     creation point is days old and creation..head re-reports every earlier job's commits.
# All must be ancestors of the branch head, so the emitted range is always a straight-line ancestry —
# which is what lets the caller use two-dot. Echoes nothing usable => the caller drops the repo.
# Bracket the Stop-time autosave the same way a tool call is bracketed. (SCRUM-1973)
#
# Not every commit a job makes happens inside a tool call: base/14 autosaves the worktree at Stop
# (SCRUM-1937), after the final PostToolUse, and a session that only ever edited files has that as
# its ONLY commit. Without a bracket around it the log shows nothing advanced and the job reports
# zero, silently defeating the autosave path.
#
# Called TWICE — `spre` immediately before the autosave and `spost` immediately after — so the
# window is the autosave itself and not the whole stretch from the last tool call to Stop. That
# stretch covers final-message generation, and treating it as a tool call would hand this job any
# commit a neighbour made in it, which is exactly the attribution rule this design exists to hold.
# The kinds are distinct from the marker's own `pre`/`post` because these lines are written with
# git: they always carry a real sha, so counting them as observations would mask a repo whose
# marker lines are all empty (packed refs / worktrees) and turn its legacy fallback into a zero.
mark_session_bracket() {
  local entry="$1" sid="${2:-}" kind="${3:-spost}" d top br sha now
  [ -n "$sid" ] || return 0
  entry="${entry/#\~/$HOME}"
  [ -n "$entry" ] || return 0
  now="${EPOCHSECONDS:-}"; [ -n "$now" ] || now=$(date +%s 2>/dev/null || echo 0)
  for d in "$entry"/*/ "$entry"/; do
    top=$(git -C "${d%/}" rev-parse --show-toplevel 2>/dev/null) || continue
    br=$(git -C "$top" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    sha=$(git -C "$top" rev-parse HEAD 2>/dev/null) || continue
    [ -n "$br" ] && [ -n "$sha" ] \
      && printf '%s\t%s\t%s\t%s\t%s\n' "$top" "$br" "$sha" "$kind" "$now" \
         2>/dev/null >> "${HOME}/.sidebutton/session-branches-${sid}.log"
  done
  return 0
}
#   $5 = the epoch second at which this job's first advancing tool call OPENED (0 = unknown).
#
# The TIME anchor is the one that survives a rewritten branch. The sha anchors are shas this session
# observed, and `git commit --amend` / `git rebase` make every one of them a non-ancestor of the new
# head — all three are then discarded and the range falls back to the branch creation point, so a
# 3-line amend on a branch an earlier job filled re-reports that job's whole diff. The newest commit
# that already existed when this job's first advancing call opened is immune: a rewrite restamps the
# committer date, so rewritten commits sort AFTER the anchor instant and only they end up in range.
branch_start_sha() {
  local r="$1" br="$2" base="${3:-}" seen="${4:-}" atime="${5:-0}" head="" cand=""
  head=$(git -C "$r" rev-parse --verify --quiet "refs/heads/${br}" 2>/dev/null) || return 1
  [ -n "$head" ] || return 1
  cand=$(git -C "$r" reflog show --format='%H' "refs/heads/${br}" 2>/dev/null | tail -1)
  [ -n "$cand" ] && ! git -C "$r" merge-base --is-ancestor "$cand" "$head" 2>/dev/null && cand=""
  [ -z "$cand" ] && cand=$(git -C "$r" merge-base origin/HEAD "$head" 2>/dev/null)
  # atime-1, never atime: `--before` is inclusive, and a `git commit` that lands in the SAME second
  # the tool call opened would otherwise be folded into the anchor and the job's own work reported as
  # zero. Erring one second wide can at worst re-admit a commit made in that same second.
  # >1e9 (i.e. a real post-2001 epoch), not >0: git SILENTLY IGNORES a --before it considers
  # implausible, and an ignored filter makes rev-list return the branch head — which would collapse
  # the range and report a job with real commits as zero. A stamp we cannot trust is no stamp.
  local a tsha=""
  case "$atime" in ''|*[!0-9]*) atime=0 ;; esac
  [ "$atime" -gt 1000000000 ] 2>/dev/null \
    && tsha=$(git -C "$r" rev-list -1 --before="@$((atime - 1))" "refs/heads/${br}" 2>/dev/null)
  for a in "$base" "$seen" "$tsha"; do
    [ -n "$a" ] || continue
    git -C "$r" merge-base --is-ancestor "$a" "$head" 2>/dev/null || continue
    if [ -z "$cand" ] || git -C "$r" merge-base --is-ancestor "$cand" "$a" 2>/dev/null; then cand="$a"; fi
  done
  [ -z "$cand" ] && cand=$(git -C "$r" rev-parse --verify --quiet "${head}~1" 2>/dev/null)
  echo "$cand"
}
capture_git_prs() {
  set +e
  local entry="$1"
  local sid="${2:-}"                    # SCRUM-1394: session id → per-session HEAD baseline (scope to repos this session advanced)
  entry="${entry/#\~/$HOME}"            # expand a leading ~ — git -C / globs never expand it (SCRUM-513 capture bug)
  [ -z "$entry" ] && { echo '[]'; return 0; }
  local baseline_file=""
  [ -n "$sid" ] && baseline_file="${HOME}/.sidebutton/session-heads-${sid}.json"
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
  local repo_url sha_end sha_start base_sha ss la ld fc co pr_url pr_number state merged_at ghj elem
  local bb_auth bb_slug branch bbj bbpr up remote_sha ahead git_churn
  local cands cand_br cand_seen cand_cross cand_time cand_t cand_start cand_end
  for r in "${uniq[@]}"; do
    repo_url=$(normalize_repo_url "$(git -C "$r" remote get-url origin 2>/dev/null)")
    # SCRUM-1394: the session-start HEAD baseline for this repo — where THIS session began.
    base_sha=""
    [ -n "$baseline_file" ] && [ -f "$baseline_file" ] && base_sha=$(jq -r --arg k "$r" '.[$k] // ""' "$baseline_file" 2>/dev/null)
    # SCRUM-1973: anchor BOTH ends of the range to the job's OWN branch. Neither endpoint may be a
    # property of the shared checkout: `rev-parse HEAD` is whatever branch a neighbour job left under
    # HEAD when this Stop fired, so baseline...HEAD cross-attributed a neighbour's commits/LOC to this
    # job (two tickets, byte-identical aggregates) and — when the neighbour branched off main instead
    # — collapsed a big feature down to the neighbour's tiny diff. Branch-scoped, both directions are
    # closed: the range is this branch's own start..head and can only contain its own commits.
    branch=""; sha_end=""; sha_start=""
    # Success here means the bracket log had usable data for this repo — INCLUDING the empty answer,
    # which is the AC: "a job that saw no commits on its own branch reports zero, not its neighbour's
    # diff". A non-zero exit is the no-data case (old box, hooks not deployed, detached HEAD, packed
    # ref) and falls through to the legacy path below rather than inventing a zero.
    if cands=$(job_branch_candidates "$r" "$sid"); then
      # Candidates are already only branches this session advanced, best first; this walk just skips
      # one that has since been deleted or rewound. Falling off the end drops the repo.
      while IFS=$'\t' read -r cand_cross cand_br cand_seen cand_time; do
        [ -n "$cand_br" ] || continue
        cand_end=$(git -C "$r" rev-parse --verify --quiet "refs/heads/${cand_br}" 2>/dev/null)
        [ -n "$cand_end" ] || continue
        if [ "$cand_cross" = "1" ]; then
          # The branch was arrived at mid-tool-call, so its anchor is the one the log supplies and
          # nothing else. Falling back to the branch creation point here would be unbounded: a
          # neighbour cutting a branch from an old commit during this call would hand us its whole
          # history. If that anchor is not even on the branch, this is not attributable — skip it.
          cand_start=""
          git -C "$r" merge-base --is-ancestor "$cand_seen" "$cand_end" 2>/dev/null && cand_start="$cand_seen"
          # …and bound it by TIME. A sha anchor alone cannot say when the commits between it and the
          # head were made, so a branch a neighbour advanced in an earlier gap was claimed whole
          # (the session-open anchor spans the neighbour's entire session; a branch the neighbour
          # cut from a commit we had been sitting on passes --is-ancestor trivially). Re-anchor at
          # the newest commit that already existed when this tool call opened: everything older is
          # by definition not this call's work. An empty answer means the whole branch postdates
          # that instant, which is exactly `git checkout -b x && git commit` — keep the sha anchor.
          case "$cand_time" in ''|*[!0-9]*) cand_time=0 ;; esac
          if [ "$cand_time" -gt 1000000000 ] 2>/dev/null; then
            # -1: see branch_start_sha — `--before` is inclusive, so a commit made in the same second
            # the call opened must stay on this job's side of the anchor. And >1e9, because git
            # silently ignores an implausible --before and then hands back the branch head.
            cand_t=$(git -C "$r" rev-list -1 --before="@$((cand_time - 1))" "refs/heads/${cand_br}" 2>/dev/null)
            if [ -n "$cand_t" ] && { [ -z "$cand_start" ] \
                 || git -C "$r" merge-base --is-ancestor "$cand_start" "$cand_t" 2>/dev/null; }; then
              cand_start="$cand_t"
            fi
          fi
          [ -n "$cand_start" ] || continue
        else
          cand_start=$(branch_start_sha "$r" "$cand_br" "$base_sha" "$cand_seen" "$cand_time")
        fi
        [ -n "$cand_start" ] && [ "$cand_start" = "$cand_end" ] && continue
        branch="$cand_br"; sha_end="$cand_end"; sha_start="$cand_start"; break
      done <<< "$cands"
      [ -z "$sha_end" ] && continue
    fi
    if [ -z "$sha_end" ]; then
      # No branch to scope to (detached HEAD / unreadable ref): legacy behaviour, so capture is never
      # worse than before. The baseline is still preferred, but only when it is an ancestor of HEAD —
      # a baseline taken on another branch would otherwise make the range a symmetric difference.
      branch=""
      sha_end=$(git -C "$r" rev-parse HEAD 2>/dev/null)
      sha_start=""
      [ -n "$base_sha" ] && git -C "$r" merge-base --is-ancestor "$base_sha" "$sha_end" 2>/dev/null && sha_start="$base_sha"
      if [ -z "$sha_start" ]; then
        sha_start=$(git -C "$r" merge-base origin/HEAD "$sha_end" 2>/dev/null)
        [ -z "$sha_start" ] && sha_start=$(git -C "$r" rev-parse --verify --quiet "${sha_end}~1" 2>/dev/null)
      fi
    fi
    # AC: a job whose own branch gained no commits reports ZERO — never its neighbour's diff. The old
    # guard compared the baseline against the shared checkout's HEAD, so a neighbour advancing HEAD
    # defeated it and the idle job emitted the neighbour's full range.
    [ -n "$sha_end" ] && [ "$sha_start" = "$sha_end" ] && continue
    # churn from the diff range (fallback / non-GitHub hosts). Two-dot: sha_start is an ancestor of
    # sha_end by construction above, so `..` and `...` agree for the diff — and `..` is the only
    # correct form for rev-list, which used to three-dot and over-counted commits (a symmetric
    # difference counts the OTHER branch's commits too whenever HEAD changed branch mid-session).
    la=""; ld=""; fc=""; co=""; git_churn=0
    if [ -n "$sha_start" ] && [ -n "$sha_end" ]; then
      ss=$(git -C "$r" diff --shortstat "${sha_start}..${sha_end}" 2>/dev/null)
      fc=$(echo "$ss" | grep -oE '[0-9]+ file'      | grep -oE '[0-9]+' | head -1)
      la=$(echo "$ss" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)
      ld=$(echo "$ss" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' | head -1)
      co=$(git -C "$r" rev-list --count "${sha_start}..${sha_end}" 2>/dev/null)
      # A real range with no insertions means 0, not "unknown" — and 0 must not read as missing
      # below, or the PR-wide fallback would overwrite a truthful zero.
      if [ -n "$co" ]; then : "${fc:=0}" "${la:=0}" "${ld:=0}"; git_churn=1; fi
    fi
    # Pushed-ness (SCRUM-1965): where the branch's remote ref stands vs HEAD. ahead=0 means every
    # commit of this turn is on the remote; ahead>0 means the push was rejected (or never ran) and
    # the work is still only on this box. Both stay empty — i.e. null, never 0 — when there is no
    # remote-tracking ref to compare against, so an old box or a never-pushed branch reads unknown.
    remote_sha=""; ahead=""
    if up=$(upstream_ref "$r" "$branch"); then
      remote_sha=$(git -C "$r" rev-parse "$up" 2>/dev/null)
      ahead=$(git -C "$r" rev-list --count "${up}..${sha_end}" 2>/dev/null)
    fi
    # PR identity + state from gh (the agent's own token). Empty on no PR / non-GitHub / unreachable.
    # SCRUM-1973: ask for the JOB's branch explicitly — a bare `gh pr view` resolves the PR of the
    # branch that happens to be checked out, i.e. the neighbour's PR on a shared checkout.
    pr_url=""; pr_number=""; state=""; merged_at=""
    ghj=$( (cd "$r" 2>/dev/null && gh pr view ${branch:+"$branch"} --json url,number,state,mergedAt,additions,deletions,changedFiles,commits 2>/dev/null) )
    if [ -n "$ghj" ]; then
      pr_url=$(echo "$ghj"     | jq -r '.url // ""')
      pr_number=$(echo "$ghj"  | jq -r '.number // empty')
      state=$(echo "$ghj"      | jq -r '.state // ""')
      merged_at=$(echo "$ghj"  | jq -r '.mergedAt // ""')
      # SCRUM-1973: PR-wide churn describes the WHOLE PR, not this job's turn on it — it used to
      # overwrite the git-derived churn unconditionally, so a 3-line follow-up job on an existing PR
      # reported the PR's entire diff (and disagreed with the sha_start/sha_end it shipped alongside).
      # Only fill in when there is no git-derived range at all. The portal reconstructs PR-grain
      # totals by max-collapsing sightings, so PR totals are not lost by keeping job grain job-scoped.
      if [ "$git_churn" != 1 ]; then
        la=$(echo "$ghj"       | jq -r '.additions // empty')
        ld=$(echo "$ghj"       | jq -r '.deletions // empty')
        fc=$(echo "$ghj"       | jq -r '.changedFiles // empty')
        co=$(echo "$ghj"       | jq -r '(.commits | length) // empty')
      fi
    fi
    # Bitbucket has no `gh`. When gh found no PR and origin is bitbucket.org, resolve PR identity +
    # state via the Bitbucket REST API with the agent's own Atlassian token (Basic base64(email:token)
    # = $BITBUCKET_AUTH_HEADER, per base/12). The git-derived churn above is kept either way; any miss
    # → churn-only with empty PR fields, never an error (SCRUM-1392 / SCRUM-1367 AC #7).
    bb_auth="${BITBUCKET_AUTH_HEADER:-}"
    if [ -z "$bb_auth" ] && [ -n "${BITBUCKET_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
      bb_auth=$(printf '%s' "${BITBUCKET_USER_EMAIL}:${BITBUCKET_API_TOKEN}" | base64 -w0 2>/dev/null)
    fi
    if [ -z "$pr_url" ] && [ -n "$bb_auth" ] && [[ "$repo_url" == *//bitbucket.org/* ]]; then
      bb_slug="${repo_url#*bitbucket.org/}"; bb_slug="${bb_slug%/}"   # {workspace}/{repo}
      # SCRUM-1973: the job's own branch, not the shared checkout's (same reason as `gh pr view`).
      [ -z "$branch" ] && branch=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)
      if [ -n "$bb_slug" ] && [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
        bbj=$(curl -4 -sfG "https://api.bitbucket.org/2.0/repositories/${bb_slug}/pullrequests" \
          --data-urlencode "q=source.branch.name=\"${branch}\"" --data-urlencode "sort=-updated_on" \
          -H "Authorization: Basic ${bb_auth}" --connect-timeout 10 --max-time 30 2>/dev/null || echo '')
        bbpr=$(echo "$bbj" | jq -c '.values[0] // empty' 2>/dev/null)
        if [ -n "$bbpr" ]; then
          pr_url=$(echo "$bbpr"    | jq -r '.links.html.href // ""')
          pr_number=$(echo "$bbpr" | jq -r '.id // empty')
          state=$(echo "$bbpr"     | jq -r '.state // ""')        # OPEN | MERGED | DECLINED | SUPERSEDED
          # Bitbucket has no native merged_on; updated_on ≈ merge time when MERGED (best-effort).
          [ "$state" = "MERGED" ] && merged_at=$(echo "$bbpr" | jq -r '.updated_on // ""')
        fi
      fi
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
      --arg remote_sha "${remote_sha:-}" --argjson ahead "${ahead:-null}" \
      '{repo_url:$repo_url, pr_url:$pr_url, pr_number:$pr_number,
        sha_start:$sha_start, sha_end:$sha_end,
        lines_added:$la, lines_deleted:$ld, files_changed:$fc, commits:$co,
        state:$state, pr_merged_at:(if $merged_at=="" then null else $merged_at end),
        remote_sha:(if $remote_sha=="" then null else $remote_sha end), ahead:$ahead}' 2>/dev/null)
    [ -n "$elem" ] && elems+=("$elem")
  done
  [ ${#elems[@]} -eq 0 ] && { echo '[]'; return 0; }
  printf '%s\n' "${elems[@]}" | jq -s '.' 2>/dev/null || echo '[]'
}

# --- Effective-route detection (SCRUM-1471 / T9) ------------------------------
# Echo a compact JSON triple {agentic_app, provider, effective_model} naming which agentic
# app + backend actually served this session, so a forked experiment branch (Jobs Experiments,
# SCRUM-1443/1473) can be labelled by route. Native Claude Code => claude-code / anthropic /
# <reported model>. Claude Code Router (CCR) re-points ANTHROPIC_BASE_URL at a local proxy
# (127.0.0.1:3456) and selects a real backend in ~/.claude-code-router/config.json — `model`
# (the transcript id) then stays an Anthropic id while the true route lives in that config.
# The LIVE ANTHROPIC_BASE_URL is authoritative (an installed-but-unrouted CCR still hits
# Anthropic), cross-checked by the config's existence. Native cloud-Claude (AAP-N, SCRUM-1611:
# Bedrock/Vertex/Foundry) instead speaks the Anthropic wire directly via CLAUDE_CODE_USE_* with NO
# proxy => provider = bedrock|vertex|foundry, effective_model = ANTHROPIC_MODEL || reported. Only
# non-secret keys are read (.Router.default / provider name / model id / CLAUDE_CODE_USE_* flags) —
# NEVER api_key, AWS/GCP/Azure creds, or env interpolation. Best-effort: any miss => native
# fallback. Pure + side-effect-free so base/tests can source and call it.
# $1 = reported (transcript) model id.
detect_effective_route() {
  local reported="${1:-}"
  local app="claude-code" provider="anthropic" emodel="$reported"
  local cfg="${HOME}/.claude-code-router/config.json"
  case "${ANTHROPIC_BASE_URL:-}" in
    *127.0.0.1:3456*|*localhost:3456*)
      if [ -f "$cfg" ]; then
        app="claude-code-router"
        provider=""          # resolved from config below; '' = CCR active but backend unknown
        local def="" prov="" mdl=""
        def=$(jq -r '.Router.default // ""' "$cfg" 2>/dev/null || echo "")
        if printf '%s' "$def" | grep -q ','; then
          # ".Router.default" is "provider,model" — strip whitespace each side may carry
          prov=$(printf '%s' "${def%%,*}" | tr -d '[:space:]')
          mdl=$(printf '%s' "${def#*,}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        else
          prov=$(jq -r '(.Providers[0].name // .Providers[0].provider) // ""' "$cfg" 2>/dev/null || echo "")
          mdl=$(jq -r '.Providers[0].models[0] // ""' "$cfg" 2>/dev/null || echo "")
        fi
        if [ -n "$prov" ]; then provider="$prov"; fi
        if [ -n "$mdl" ]; then emodel="$mdl"; fi
      fi
      ;;
    *)
      # Native cloud-Claude (AAP-N, SCRUM-1611): Bedrock/Vertex/Foundry speak the Anthropic wire
      # DIRECTLY (no proxy) — chosen by CLAUDE_CODE_USE_*, so ANTHROPIC_BASE_URL is unset (or a plain
      # gateway) and the run would otherwise mislabel as bare `anthropic`. Tag the real cloud backend
      # so cost is provider-metered, not mis-attributed. A valid native-cloud app sets exactly one
      # USE_* flag; ANTHROPIC_MODEL (the operator-pinned inference-profile / model id) is the
      # authoritative route id, else the transcript model. Non-secret env only (flags + model id) —
      # never AWS/GCP/Azure credentials.
      if [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
        provider="bedrock"; emodel="${ANTHROPIC_MODEL:-$reported}"
      elif [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ]; then
        provider="vertex"; emodel="${ANTHROPIC_MODEL:-$reported}"
      elif [ "${CLAUDE_CODE_USE_FOUNDRY:-}" = "1" ]; then
        provider="foundry"; emodel="${ANTHROPIC_MODEL:-$reported}"
      fi
      ;;
  esac
  jq -nc --arg a "$app" --arg p "$provider" --arg m "$emodel" \
    '{agentic_app:$a, provider:$p, effective_model:$m}' 2>/dev/null \
    || printf '{"agentic_app":"%s","provider":"%s","effective_model":"%s"}\n' "$app" "$provider" "$emodel"
}

# --- Per-run auth-identity stamp (AUTH-4, SCRUM-1629 / PROVIDER-AUTH-VISIBILITY.md §7) -------------
# Echo a compact NON-SECRET JSON object {method, id, base_host?} naming the auth identity that
# actually served this run — the subscription / key / cloud principal that spent the quota — so the
# portal can attribute burn to it (jobs.auth_identity) and roll up usage-by-identity. Parallels
# detect_effective_route: rides the SAME /api/jobs/usage POST, best-effort, pure + side-effect-free
# (base/tests source & call it). Precedence mirrors Claude Code's own (env token wins over the login):
#   token in effect (ANTHROPIC_API_KEY ‖ ANTHROPIC_AUTH_TOKEN) → id = its FINGERPRINT (§4.3); method
#       `gateway` when a non-local ANTHROPIC_BASE_URL is present (carry its host), else `api_key`.
#   else native cloud (CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY=1) → method bedrock|vertex|foundry, id = a
#       best-effort principal from env (AWS_PROFILE / Vertex project) — NEVER `aws sts`/`gcloud` at Stop
#       (that would tax every Stop); omit id (→ whole stamp omitted) on a miss.
#   else direct Anthropic with NO token → subscription: id = ~/.claude.json oauthAccount email (the
#       quota boundary; portal renders `run as <email>`).
#   CCR runs (ANTHROPIC_BASE_URL = the local proxy) → method `ccr` (SCRUM-1631): the env names only the
#       proxy — the identity that SPENT the quota is the UPSTREAM key in ~/.claude-code-router/config.json,
#       so id = ITS fingerprint and base_host = its endpoint. NEVER the proxy's own sbccr_ dummy token.
# Non-secret by construction: only a fingerprint, an endpoint host, an operator-owned email / profile name
# — never a raw token, never AWS/GCP credentials. Any miss => '{}' → the portal leaves the row unstamped
# (legacy-safe). The §4.3 fingerprint reproduces the reporter's fingerprint() (report-health-snapshot.sh)
# — bash+jq can't import the Python helper — so a run's key stamp groups with the agent's.
fp_token() {
  # §4.3: first-6 + … + last-4; tokens under 12 chars render last-2 only. Never the middle, never the whole value.
  local t="${1:-}"
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"   # trim surrounding whitespace (parity with .strip())
  [ -z "$t" ] && return 0
  if [ "${#t}" -lt 12 ]; then printf '…%s' "${t: -2}"; else printf '%s…%s' "${t:0:6}" "${t: -4}"; fi
}

# Host of a NON-LOCAL URL (a real endpoint), else nothing — a loopback host is not an identity.
# Mirrors the reporter's _base_host() so a run's stamp and the agent's block agree on the host.
url_host() {
  local u="${1:-}" hp="" h=""
  [ -n "$u" ] || return 0
  u="${u#[\"\']}"; u="${u%[\"\']}"                 # a quoted env value is not a quoted host (parity with .strip('"'))
  hp="${u#*://}"; hp="${hp%%/*}"                   # drop scheme + path
  # Drop userinfo. `##*@` cuts at the LAST @, exactly as urlparse's netloc.rpartition('@') does.
  # Without this a credentialed endpoint (`https://tok@api.z.ai/v1` — legal for openai-compatible
  # upstreams) stamps `tok@api.z.ai`, i.e. part of a SECRET, into a payload and a log line that are
  # non-secret by construction.
  hp="${hp##*@}"
  case "$hp" in
    # Bracketed IPv6 literal: `[::1]:3456` -> `::1`. Splitting on the first colon instead would
    # yield `[`, which is not just wrong but slips past the loopback check below — the one filter
    # that keeps the local CCR proxy from being stamped as though it were the upstream endpoint.
    '['*) h="${hp#\[}"; h="${h%%\]*}" ;;
    *)    h="${hp%%:*}" ;;                         # host[:port]
  esac
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
  case "$h" in localhost|127.0.0.1|0.0.0.0|::1|'') return 0 ;; esac
  printf '%s' "$h"
}

# Resolve a CCR config.json value: a LITERAL (portal-delivered app row) or the install-time template's
# `$VAR` / `${VAR}` placeholder, which CCR itself interpolates at runtime from ccr.service's
# EnvironmentFile — so what is on disk may be the literal string `$CCR_PROVIDER_API_KEY`. Echoes nothing
# when a placeholder resolves to nothing: stamping an unresolved `$VAR` would fabricate an identity that
# every unrouted CCR box would then share. Resolution is BY THE VAR'S OWN NAME, exactly as CCR does it —
# a config that simply omits a field is a config with no upstream key, not an invitation to guess from env.
ccr_deref() {
  local v="${1:-}" name=""
  case "$v" in
    '$'*)
      name="${v#\$}"; name="${name#\{}"; name="${name%\}}"
      case "$name" in ''|*[!A-Za-z0-9_]*) v="" ;; *) v="${!name:-}" ;; esac
      ;;
  esac
  printf '%s' "$v"
}

detect_run_identity() {
  local base="${ANTHROPIC_BASE_URL:-}"
  local method="" id="" base_host="" is_ccr=0
  # CCR local proxy — routed one hop further out; resolved in the first branch below (SCRUM-1631).
  case "$base" in *127.0.0.1:3456*|*localhost:3456*) is_ccr=1 ;; esac

  # base_host = host of a NON-LOCAL ANTHROPIC_BASE_URL (a gateway endpoint); a local host is not an identity.
  base_host="$(url_host "$base")"

  # A token in effect: ANTHROPIC_API_KEY, else ANTHROPIC_AUTH_TOKEN (mirrors the reporter's _token_of).
  local tok="${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
  if [ "$is_ccr" = 1 ]; then
    # CCR (SCRUM-1631): $tok here is the local sbccr_ dummy Claude Code presents to the proxy, and $base
    # is loopback — neither is an identity. The quota was spent by the UPSTREAM key in the router config,
    # so stamp ITS fingerprint + endpoint. Checked FIRST and never falling through to the token branch
    # below: that would fingerprint the dummy, the exact mis-attribution this branch replaces.
    local cfg="${HOME}/.claude-code-router/config.json" ukey="" uurl=""
    if [ -f "$cfg" ]; then
      ukey="$(ccr_deref "$(jq -r '.Providers[0].api_key    // ""' "$cfg" 2>/dev/null || echo "")")"
      uurl="$(ccr_deref "$(jq -r '.Providers[0].api_base_url // ""' "$cfg" 2>/dev/null || echo "")")"
    else
      # Legacy cloud-init contract (pre-SCRUM-1613): the upstream arrived as CCR_PROVIDER_* env with no
      # config on disk. Only reachable with NO config at all — mirrors the reporter's _collect_ccr gate.
      ukey="${CCR_PROVIDER_API_KEY:-}"; uurl="${CCR_PROVIDER_API_BASE_URL:-}"
    fi
    if [ -n "$ukey" ]; then
      method="ccr"; id="$(fp_token "$ukey")"
      base_host="$(url_host "$uurl")"
    fi
  elif [ -n "$tok" ]; then
    id="$(fp_token "$tok")"
    if [ -n "$base_host" ]; then method="gateway"; else method="api_key"; fi
  elif [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
    method="bedrock"; id="${AWS_PROFILE:-}"                  # principal, best-effort; no `aws sts` at Stop
  elif [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ]; then
    method="vertex";  id="${ANTHROPIC_VERTEX_PROJECT_ID:-}"  # non-secret project id from env; no `gcloud` at Stop
  elif [ "${CLAUDE_CODE_USE_FOUNDRY:-}" = "1" ]; then
    method="foundry"; id=""                                 # no non-secret principal available at Stop → omit
  else
    # Direct Anthropic, no token → subscription identity from ~/.claude.json oauthAccount (the quota boundary).
    id="$(jq -r '.oauthAccount.emailAddress // empty' "${HOME}/.claude.json" 2>/dev/null || echo "")"
    if [ -n "$id" ]; then method="subscription"; fi
  fi

  # Require a usable (method,id) pair; else omit — a partial stamp is worse than none (best-effort).
  if [ -z "$method" ] || [ -z "$id" ]; then printf '{}'; return 0; fi
  jq -nc --arg m "$method" --arg i "$id" --arg h "$base_host" \
    '{method:$m, id:$i} + (if $h != "" then {base_host:$h} else {} end)' 2>/dev/null \
    || printf '{"method":"%s","id":"%s"}' "$method" "$id"
}

# --- session-stopped sentinel writer (SCRUM-1769) -----------------------------
# Mark a finished session so sb-session-tidy (base/19e) can close its idle TUI
# ~SB_SESSION_CLOSE_TTL_SEC later. A dispatched job launches Claude as an
# interactive TUI that never exits when the run ends; since PR #75 retired the
# reaper nothing closes them, so they accumulate until the box OOM-livelocks
# (23 claude procs = 7.7GB at the 2026-07-17 darwin OOM).
#
# The sentinel carries the PID and its /proc starttime rather than only the
# session id, so the sweep signals a process it has positively identified instead
# of mapping sid -> process by parsing --session-id out of /proc/*/cmdline (what
# the retired gen-3 did). That matters for `claude --continue`, which resumes the
# SAME session id in a NEW process: the stale sentinel carries the OLD pid, the
# starttime check fails, and the sweep prunes the sentinel instead of killing the
# live resumed session.
#
# STRICTLY best-effort — this is the one thing in this change that could be worse
# than the bug. The hook runs `set -euo pipefail` and this writer lands BEFORE the
# usage + step-complete POSTs that PR #75 made the SOLE completion signal, so any
# non-zero here would abort the hook and strand EVERY job as 'running', fleet-wide.
# Every step is guarded and the call site adds `|| true`, which also suspends -e
# for the whole function body. A leaked TUI is recoverable; a stranded job is not.
mark_session_stopped() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 0
  # sid comes from hook stdin JSON and becomes a filename — charset-validate it.
  case "$sid" in
    .|..|*[!A-Za-z0-9._-]*) log "session id unusable as a sentinel name — skipped"; return 0 ;;
  esac
  # Nearest ancestor with comm exactly `claude` (claude -> shell -> this hook, so
  # the walk is 1-2 hops; bounded anyway). PPid comes from /proc/<p>/status, NOT
  # field 4 of /proc/<p>/stat — a comm containing spaces shifts stat's fields.
  local p="${PPID:-}" pid="" hops=0 comm=""
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$hops" -lt 12 ]; do
    comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
    if [ "$comm" = "claude" ]; then pid="$p"; break; fi
    p=$(awk '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null || true)
    hops=$(( hops + 1 ))
  done
  [ -n "$pid" ] || { log "no claude ancestor for session $sid — sentinel skipped"; return 0; }
  # starttime = /proc/<pid>/stat field 22. comm (field 2) is parenthesized and may
  # contain spaces/parens, so cut everything through the LAST ") " and index from
  # field 3: 22 - 2 = 20. Safe regardless of what comm holds.
  local stat_line rest pid_start=""
  stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || true)
  rest="${stat_line##*) }"
  pid_start=$(printf '%s' "$rest" | awk '{print $20}' 2>/dev/null || true)
  case "${pid_start:-}" in
    ''|*[!0-9]*) log "unreadable starttime for pid $pid — sentinel skipped"; return 0 ;;
  esac
  local dir="${HOME}/.sidebutton/session-stopped"
  mkdir -p "$dir" 2>/dev/null || { log "cannot create $dir — sentinel skipped"; return 0; }
  # Atomic tmp + mv: the 5-min sweep must never read a half-written sentinel.
  local tmp="${dir}/.${sid}.$$.tmp"
  if jq -nc --argjson pid "$pid" --argjson pid_start "$pid_start" \
       --argjson stopped_at "$(date +%s)" \
       '{pid:$pid, pid_start:$pid_start, stopped_at:$stopped_at}' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "${dir}/${sid}.json" 2>/dev/null; then
    log "session-stopped sentinel written for $sid (pid=$pid start=$pid_start)"
  else
    rm -f "$tmp" 2>/dev/null || true
    log "sentinel write failed for $sid — continuing to the completion POSTs"
  fi
  return 0
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
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // empty')

# SCRUM-1769: mark this finished session for sb-session-tidy (base/19e), BEFORE the
# job-session gate below. The sentinel is a LOCAL lifecycle marker, not a portal
# post — it carries no job state and the sweep never consults completion — so it
# must be dropped for EVERY finished session, including one the gate is about to
# exit on. Lingering previous sessions and operator windows are precisely the ones
# that accumulate; gating this like the portal posts would leave them unmarked and
# therefore never closed, i.e. the leak this ticket fixes.
#
# Only the real Stop marks completion: SubagentStop fires when a sub-agent returns
# while the main agent is still working, so marking there would arm the sweep
# against a live session.
#
# `|| true` on a best-effort local marker that runs ahead of the sole completion
# signal — see the mark_session_stopped header.
if [ "$HOOK_EVENT" = "Stop" ]; then
  mark_session_stopped "$SESSION_ID" || true
fi

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
# completion. final=true only for hook_event_name == "Stop". (HOOK_EVENT is parsed
# once up top, near SESSION_ID; reused here and to gate the transcript upload below.)
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
# Effective route (SCRUM-1471 / T9): tag this session's usage with the agentic app + provider +
# effective model that actually served it. Carried INSIDE `usage` alongside `model`; the portal
# persists it to job_steps and rolls it up to jobs (most-recent non-empty). Best-effort: a broken
# detection degrades to '{}' and the portal keeps the empty defaults. NOT added to the step-complete
# POST below — that carries no `usage`, so a partial object there would clobber model/tokens.
REPORTED_MODEL=$(printf '%s' "$USAGE" | jq -r '.model // ""' 2>/dev/null || echo "")
ROUTE_JSON=$(detect_effective_route "$REPORTED_MODEL" 2>/dev/null || echo '{}')
case "$ROUTE_JSON" in ''|null) ROUTE_JSON='{}' ;; esac
# Per-run auth identity (AUTH-4, SCRUM-1629 / §7): the subscription/key/cloud principal that spent this
# run's quota. Rides INSIDE `usage` alongside the route triple; the portal validates + size-bounds it,
# writes job_steps.auth_identity, and rolls it up to jobs.auth_identity (most-recent non-empty). Best-effort:
# a miss / CCR / legacy degrades to '{}' → the key is omitted and the row stays unstamped. NOT added to the
# step-complete POST below (it carries no `usage` — a partial object there would clobber model/tokens), same
# rule as the route triple.
IDENT_JSON=$(detect_run_identity 2>/dev/null || echo '{}')
case "$IDENT_JSON" in ''|null) IDENT_JSON='{}' ;; esac
log "effective route: $ROUTE_JSON identity: $IDENT_JSON (base=${ANTHROPIC_BASE_URL:-unset})"
PAYLOAD=$(jq -n --argjson job_id "${JOB_ID:-null}" --argjson step "${STEP_INDEX:-null}" \
  --arg sid "$SESSION_ID" --argjson u "$USAGE" \
  --argjson dur "$DURATION_MS" --arg cost "$TOTAL_COST" \
  --argjson final "$IS_FINAL" --argjson route "$ROUTE_JSON" --argjson ident "$IDENT_JSON" \
  '{job_id:$job_id, step_index:$step, session_id:$sid, final:$final,
    usage:($u + {duration_ms:$dur, total_cost_usd_reported:($cost|tonumber)} + $route
           + (if ($ident|type) == "object" and ($ident|length) > 0 then {auth_identity:$ident} else {} end))}')
# --retry: these two POSTs are the ONLY completion signal — a single portal
# blip (deploy restart, 5xx) at Stop time must not strand the job as
# 'running'. --retry-all-errors covers connection-refused during a restart;
# both endpoints are idempotent, so a duplicate delivery is harmless.
# --max-time bounds the whole operation including retries.
curl -4 -sf -X POST "${PORTAL_URL}/api/jobs/usage" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$PAYLOAD" --connect-timeout 10 --max-time 90 \
  --retry 3 --retry-delay 2 --retry-all-errors >/dev/null 2>&1 || true
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
  # SCRUM-1937 (SP-D): on an app_edit_session turn ONLY, autosave the worktree and kick the
  # debounced staged republish. Deliberately ahead of capture_git_prs so the autosave commit
  # has already advanced HEAD and lands in jobs.prs. This is the critical path in front of the
  # completion POSTs, so it is three lines that cannot fail: the helper itself is gate-first,
  # never `set -e`, and always exits 0 (see its header) — the `|| true` and the -x test are
  # belt on top, and a box without the helper simply skips it.
  # SCRUM-1973: bracket the autosave exactly like a tool call — open immediately before it, close
  # immediately after — so a commit it makes counts as this job's work while the long stretch since
  # the last tool call (final-message generation) stays outside the window, where a neighbour's
  # commit belongs to the neighbour.
  mark_session_bracket "$ENTRY_PATH" "$SESSION_ID" spre 2>/dev/null || true
  if [ -x "${HOME}/.local/bin/sb-app-autosave.sh" ]; then
    "${HOME}/.local/bin/sb-app-autosave.sh" turn "$ENTRY_PATH" "$SESSION_ID" </dev/null >/dev/null 2>&1 || true
  fi
  mark_session_bracket "$ENTRY_PATH" "$SESSION_ID" spost 2>/dev/null || true
  PRS_JSON=$(capture_git_prs "$ENTRY_PATH" "$SESSION_ID" 2>/dev/null || echo '[]')
  case "$PRS_JSON" in ''|'[]') PRS_JSON='[]' ;; esac
  log "git telemetry: $(echo "$PRS_JSON" | jq -c 'length') PR(s) from $ENTRY_PATH"
  STEP_COMPLETE_PAYLOAD=$(jq -n --argjson job_id "${JOB_ID:-null}" --argjson step "${STEP_INDEX:-null}" \
    --arg msg "$OUTPUT_MSG" --arg sid "$SESSION_ID" --argjson prs "$PRS_JSON" \
    '{job_id:$job_id, step_index:$step, session_id:$sid, status:"success", output_message:$msg}
      + (if ($prs|length) > 0 then {prs:$prs} else {} end)')
  # Retried like the usage POST above — completion must survive a portal blip.
  curl -4 -sf -X POST "${PORTAL_URL}/api/jobs/step-complete" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AGENT_TOKEN}" \
    -H "X-Agent-Name: ${AGENT_NAME}" \
    -d "$STEP_COMPLETE_PAYLOAD" --connect-timeout 10 --max-time 90 \
    --retry 3 --retry-delay 2 --retry-all-errors >/dev/null 2>&1 || true
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
      # Clear the file only on a 2xx so the NEXT job's Stop can't re-glob and re-POST it
      # under a different job_id/step_index/session_id (SCRUM-1604 cross-job artifact
      # mis-attribution — server upsert is per-job, so it doesn't protect across jobs).
      # A non-2xx or curl-fail (AR_CODE=0) file is left in place for the next Stop's
      # retry. Guarded + non-fatal, matching this hook's stay-invisible-to-Claude contract.
      case "$AR_CODE" in 2*) rm -f "$f" 2>/dev/null || true ;; esac
    done < <(find "$ART_DIR" -maxdepth 3 -type f ! -name '.*' -print0 2>/dev/null)
    log "artifacts: posted ${ART_N} file(s) from ${ART_DIR}"
  fi
fi
exit 0
HOOKEOF
chmod +x "$AGENT_HOME/.local/bin/claude-stop-hook.sh"
