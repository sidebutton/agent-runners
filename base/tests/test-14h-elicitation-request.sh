#!/usr/bin/env bash
# base/tests/test-14h-elicitation-request.sh — regression guard for KAN-205 (c): a session blocked
# on an MCP elicitation dialog, a URL elicitation, or an explicit needs-input notification must
# open a Needs-you row, and idle_prompt must still NOT.
#
# The defect: sb-post-request.sh's `Notification)` case opened a row for `permission_prompt` only.
# `elicitation_dialog`, `elicitation_url_dialog` and `agent_needs_input` all fell through to
# `*) exit 0`, so a session blocked on one of them showed as BUSY with no operator signal
# anywhere — not on the Needs-you band, not in the chat rail. All three names ship as string
# literals in the CLI (2.1.251+), so this is a live blind spot, not a hypothetical one.
#
# The four properties this guard pins, all on the WRITE side:
#   1. each of the three types opens exactly one row                     (KAN-205 AC3)
#   2. the row is kind=question — the ONLY kind the portal accepts today without a schema change
#      (AgentRequestKind is question|permission|plan|idle, validated at POST; a fourth kind is a
#      400 at capture, i.e. no row at all)
#   3. the row actually SAYS something: the notification's message survives into the payload, and
#      payload.notification_type keeps which of the three raised it
#   4. idle_prompt / auth_success still post nothing — capturing idle_prompt spammed Needs-you
#      from idle, post-job and between-job sessions, and the operator-requests pack marks that
#      "do not fix". This guard exists partly so a later edit to the `case` cannot quietly undo it.
#
# Same harness as test-14f: the helper is extracted from base/14's own heredoc, so every case
# drives the REAL shipped code. Isolated: fake HOME, stubbed `curl` (argv recorder — no network,
# no portal row). Needs bash + jq. Run: bash base/tests/test-14h-elicitation-request.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; return 1; }
skip() { printf 'skip - %s\n' "$1"; }

bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — every assertion below needs it"
  echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

awk "/cat > .*sb-post-request.sh.*<<'PREOF'/{f=1;next} /^PREOF\$/{f=0} f" "$HOOK" > "$TMP/sb-post-request.sh"
[ -s "$TMP/sb-post-request.sh" ] || { bad "could not extract sb-post-request.sh (heredoc marker moved?)"; echo; echo "FAILURES"; exit 1; }
bash -n "$TMP/sb-post-request.sh" && ok "bash -n: sb-post-request.sh (the heredoc body really parses)" \
  || { bad "sb-post-request.sh does not parse — a live agent would die on every notification"; echo; echo "FAILURES"; exit 1; }

export HOME="$TMP/home"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$TMP/stub"
cp "$TMP/sb-post-request.sh" "$HOME/.local/bin/"; chmod +x "$HOME/.local/bin"/*.sh
printf 'AGENT_TOKEN=sb_test\nAGENT_NAME=test-agent\nPORTAL_URL=http://portal.invalid\n' > "$HOME/.agent-env"
echo '{"session_id":"S"}' > "$HOME/.sidebutton/job-context.json"

cat > "$TMP/stub/curl" <<'CURLEOF'
#!/usr/bin/env bash
for ((i=1;i<=$#;i++)); do
  if [ "${!i}" = "-d" ]; then j=$((i+1)); printf '%s\n' "${!j}" >> "$CURL_LOG"; fi
done
exit 0
CURLEOF
chmod +x "$TMP/stub/curl"
export CURL_LOG="$TMP/curl.log"

fire() { printf '%s' "$2" | env -i PATH="$TMP/stub:$PATH" HOME="$HOME" CURL_LOG="$CURL_LOG" \
           bash "$HOME/.local/bin/$1"; }
# The forwarder BACKGROUNDS its curl, so wait for the child to land. A negative case cannot use
# the same early-break wait (there is nothing to wait FOR), so it sleeps the full budget once.
post()   { : > "$CURL_LOG"; fire "$1" "$2"; for _ in $(seq 10); do [ -s "$CURL_LOG" ] && break; sleep 0.1; done; }
nopost() { : > "$CURL_LOG"; fire "$1" "$2"; sleep 1; }
posts()  { [ -f "$CURL_LOG" ] && wc -l < "$CURL_LOG" | tr -d ' ' || echo 0; }
body()   { tail -1 "$CURL_LOG"; }
notif()  { printf '{"hook_event_name":"Notification","session_id":"S","notification_type":"%s","message":"%s","title":"Claude Code"}' "$1" "$2"; }

# An EMPTY message is not a hypothetical: `//` in jq only catches null and false, so `"message":""`
# sails straight through a `.message // .title` chain and lands a row whose one text field is blank.
# The fallback must treat "" as absent — title first, then the type name, so the row always says
# something an operator can act on.
empty_msg_case() {
  local B
  post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"elicitation_dialog","message":"","title":"Claude Code"}'
  B="$(body)"
  echo "$B" | jq -e '.payload.questions[0].question | startswith("Claude Code")' >/dev/null 2>&1 \
    && ok "an empty .message falls back to .title (jq's // would have passed \"\" through)" \
    || bad "empty message produced: $(echo "$B" | jq -c '.payload.questions[0].question' 2>/dev/null)"
  post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"elicitation_dialog","message":"","title":""}'
  B="$(body)"
  echo "$B" | jq -e '.payload.questions[0].question | startswith("elicitation_dialog")' >/dev/null 2>&1 \
    && ok "…and with no title either, to the block type — the question is never empty" \
    || bad "empty message+title produced: $(echo "$B" | jq -c '.payload.questions[0].question' 2>/dev/null)"
}

# ── 1. each blocking notification type opens exactly one row that says something ────────────────
check_type() {  # $1=notification_type  $2=message
  local t="$1" m="$2" B
  post sb-post-request.sh "$(notif "$t" "$m")"
  [ "$(posts)" = 1 ] \
    && ok "$t opens exactly one row (it used to open none)" \
    || { bad "$t posted $(posts) requests, expected 1 — the session is invisible while blocked"; return; }
  B="$(body)"
  echo "$B" | jq -e --arg t "$t" '.action == "open" and .session_id == "S" and .tool_use_id == "notif-\($t)"' >/dev/null 2>&1 \
    && ok "$t is keyed notif-$t — stable across a re-notification, distinct from the other types" \
    || bad "$t wrong envelope/key: $(echo "$B" | jq -c '{action,session_id,tool_use_id}' 2>/dev/null)"
  # kind MUST be one the portal already accepts. A fourth kind is rejected at POST
  # /api/agents/requests (isAgentRequestKind), so the row would never exist at all.
  echo "$B" | jq -e '.kind == "question"' >/dev/null 2>&1 \
    && ok "$t is captured as kind=question (the portal accepts and renders it today)" \
    || bad "$t has kind $(echo "$B" | jq -c '.kind' 2>/dev/null) — not in AgentRequestKind, a 400 at capture"
  # Without this the operator gets a needs-you row with no text in it: Notification events carry
  # no .tool_input, so the AskUserQuestion payload branch would have built questions: [].
  # CONTAINS, not equals: the question is the message PLUS where to answer it. For two of the three
  # types Claude Code's own .message is a compile-time constant ("Claude Code needs your input" /
  # "An MCP server needs your input", 2.1.251), so a row carrying only the message names neither
  # the server nor the ask — and the dialog lives on the VM desktop with no return path through
  # this row, so the portal's answer box cannot clear it. An equality assertion here would also
  # only ever have proved that an INVENTED fixture message round-trips.
  echo "$B" | jq -e --arg m "$m" '.payload.questions[0].question | startswith($m)' >/dev/null 2>&1 \
    && ok "$t carries its message as the question (not an empty questions[])" \
    || bad "$t payload has no question text: $(echo "$B" | jq -c '.payload' 2>/dev/null)"
  echo "$B" | jq -e --arg t "$t" '.payload.questions[0].question | test("Live desktop") and test($t)' >/dev/null 2>&1 \
    && ok "$t question also says WHERE to answer it, and names the block type" \
    || bad "$t question does not point at the desktop: $(echo "$B" | jq -c '.payload.questions[0].question' 2>/dev/null)"
  # The raw message stays available unmodified for anything that wants it without the hint.
  echo "$B" | jq -e --arg m "$m" '.payload.message == $m' >/dev/null 2>&1 \
    && ok "$t keeps the unannotated message in payload.message" \
    || bad "$t lost its raw message: $(echo "$B" | jq -c '.payload.message' 2>/dev/null)"
  echo "$B" | jq -e '(.payload.questions[0].options | type) == "array"' >/dev/null 2>&1 \
    && ok "$t renders as an option-less question (the dialog itself lives on the VM desktop)" \
    || bad "$t options are not an array: $(echo "$B" | jq -c '.payload.questions[0]' 2>/dev/null)"
  # Reusing `question` is what avoids the portal change; this field is what stops that reuse from
  # ERASING which block it was.
  echo "$B" | jq -e --arg t "$t" '.payload.notification_type == $t' >/dev/null 2>&1 \
    && ok "$t keeps its identity in payload.notification_type" \
    || bad "$t lost its type in the payload: $(echo "$B" | jq -c '.payload' 2>/dev/null)"
}
check_type elicitation_dialog      "An MCP server is asking for confirmation"
check_type elicitation_url_dialog  "Open this URL to authorize the connection"
check_type agent_needs_input       "Claude needs your input to continue"
empty_msg_case

# ── 2. the three keys really are distinct ───────────────────────────────────────────────────────
# One session can raise more than one type; if they collapsed onto a single key the second would
# overwrite the first's payload and inherit its answer — the KAN-203 hazard, re-introduced.
post sb-post-request.sh "$(notif elicitation_dialog "first")";     K1="$(body | jq -r '.tool_use_id')"
post sb-post-request.sh "$(notif agent_needs_input  "second")";    K2="$(body | jq -r '.tool_use_id')"
[ -n "$K1" ] && [ "$K1" != "$K2" ] \
  && ok "two different block types in one session get their own rows ($K1 vs $K2)" \
  || bad "the three types collapse onto one key ($K1) — one would inherit the other's answer"

# ── 3. a re-notification of ONE block stays ONE row ─────────────────────────────────────────────
post sb-post-request.sh "$(notif elicitation_dialog "first")"
[ "$(body | jq -r '.tool_use_id')" = "notif-elicitation_dialog" ] \
  && ok "a re-fired notification for one block is idempotent (same key, an upsert)" \
  || bad "a re-notification minted a different key — the operator gets a new row each time"

# ── 4. the fall-through still drops what must stay dropped ──────────────────────────────────────
# idle_prompt is a self-resolving machine state surfaced by the portal's IDLE counter. Capturing it
# spammed Needs-you from idle/post-job/between-job sessions; agent-runners/operator-requests records
# that and marks it "do not fix". KAN-205 extends the `case`, it does not replace the fall-through.
for t in idle_prompt auth_success; do
  nopost sb-post-request.sh "$(notif "$t" "nothing to see")"
  [ "$(posts)" = 0 ] \
    && ok "$t still posts nothing (the fall-through is intact)" \
    || bad "$t opened a row — Needs-you will be spammed from idle sessions"
done

# ── 5. the pre-existing permission arm is untouched ─────────────────────────────────────────────
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","title":"Claude Code"}'
B="$(body)"
echo "$B" | jq -e '.kind == "permission" and (.tool_use_id | startswith("notif-permission")) and (.payload.message | test("permission to use Bash"))' >/dev/null 2>&1 \
  && ok "permission_prompt still opens its own kind=permission row (KAN-203 shape intact)" \
  || bad "the permission arm regressed: $B"

# ── 6. a session that is not the job session is still dropped ──────────────────────────────────
nopost sb-post-request.sh '{"hook_event_name":"Notification","session_id":"OTHER","notification_type":"elicitation_dialog","message":"x"}'
[ "$(posts)" = 0 ] \
  && ok "a foreign session's elicitation is dropped by the job-session gate" \
  || bad "the job-session gate no longer applies to the new arm"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
