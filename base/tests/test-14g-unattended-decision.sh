#!/usr/bin/env bash
# base/tests/test-14g-unattended-decision.sh — regression guard for KAN-204: an unanswered
# AskUserQuestion must not block an unattended agent run indefinitely.
#
# Prod evidence (2026-09-09, 49 agent_requests rows / 27 of kind `question`): only 14 questions
# were ever answered through the portal, one row sat blocked for 21.8 days, and two were still open
# at filing. The chain: sb-await-decision.sh long-polled for 100s, gave up, wrote NOTHING, and on
# Claude Code's PreToolUse contract silence means "proceed" — so the tool proceeded and rendered a
# modal dialog on a VM desktop nobody was watching. The agent held its slot; the job never finished.
#
# Everything here drives the REAL shipped code: the waiter is extracted from base/14's heredoc and
# fired exactly as Claude Code fires it — hook JSON on stdin, `env -i`, a fake HOME, and a `curl`
# stub that answers the long-poll and records the POSTed body. No network, no portal row.
#
# The properties this guard pins:
#   1. expiry on an unattended job session is a DECISION, not silence          (KAN-204 AC1)
#   2. the steer rides additionalContext, never the deny reason alone          (KAN-204 note 3)
#   3. the auto-pick is the option the prompt marks (Recommended), agent-side
#   4. the waiter closes its own portal row when it auto-decides               (KAN-204 AC4)
#   5. an operator answer inside the budget still wins                         (KAN-204 AC2)
#   6. attended boxes / operator sessions / optionless prompts fall through    (KAN-204 AC3)
#   7. the wired hook timeout stays above the compiled-in budget               (the ceiling bug)
#   8. the loop backs off on EVERY iteration, not just an empty response       (the poll storm)
# Plus (6) again as the invariant that outranks all of them: never decide on uncertainty.
#
# Needs bash + jq. Run: bash base/tests/test-14g-unattended-decision.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
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

# ── 1. the wiring: the waiter is installed, and its ceiling is above its budget ──────────────────
# The two numbers live in DIFFERENT FILES with nothing tying them together, and that is exactly how
# the bug survived: raising SB_REQUEST_WAIT_TOTAL alone is SIGKILLed at the wired `timeout` with rc
# 124 and no output — the same silent fallthrough, reached faster.
WIRED=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="AskUserQuestion|ExitPlanMode") | .hooks[]
               | select(.command | test("sb-await-decision\\.sh")) | .timeout // empty' \
        "$HOOKS_JSON" 2>/dev/null)
[ -n "$WIRED" ] && ok "claude-hooks.json wires sb-await-decision.sh with an explicit timeout (${WIRED}s)" \
  || bad "sb-await-decision.sh has no wired timeout — Claude Code would apply its own default"

extract() {  # $1=basename  $2=heredoc marker
  awk "/cat > .*$1.*<<'$2'/{f=1;next} /^$2\$/{f=0} f" "$HOOK" > "$TMP/$1"
  [ -s "$TMP/$1" ] || { bad "could not extract $1 from base/14 (heredoc marker $2 moved?)"; return 1; }
  bash -n "$TMP/$1" && ok "bash -n: $1 (the heredoc body really parses)" \
    || bad "$1 does not parse — a live agent would die on every needs-input prompt"
}
extract sb-await-decision.sh AWAITEOF || { echo; echo "FAILURES: 1"; exit 1; }
WAITER="$TMP/sb-await-decision.sh"

# The compiled-in job ceiling, read out of the shipped script rather than restated here.
CEIL=$(sed -n 's/.*CEIL=\([0-9]\+\).*job: long-poll.*/\1/p' "$WAITER" | head -1)
[ -n "$CEIL" ] && ok "the job-session budget is clamped in-script (CEIL=${CEIL}s)" \
  || bad "no compiled-in job ceiling found — an over-large env budget would be obeyed and then killed"
if [ -n "$CEIL" ] && [ -n "$WIRED" ]; then
  # One poll cycle is WAIT_PER + the curl --max-time slack (10s), plus the resolve POST (~7s).
  if [ "$WIRED" -gt $((CEIL + 42)) ]; then
    ok "wired timeout ${WIRED}s clears the ${CEIL}s budget + a poll cycle + the resolve POST"
  else
    bad "wired timeout ${WIRED}s is too close to the ${CEIL}s budget — the hook is killed mid-poll and emits nothing"
  fi
fi
grep -q 'SB_REQUEST_WAIT_TOTAL:-900' "$WAITER" \
  && ok "the job budget is 900s, not the 100s that expired on essentially every real prompt" \
  || bad "the job budget is not 900s — real operator latency is tens of minutes to days"
# …and the long budget is scoped to the lane that AUTO-DECIDES at the end of it. An attended /
# opted-out job session still falls through to the Live desktop, so raising ITS budget buys nothing
# and costs the only thing that lane has: an operator sitting at that desktop would wait 15 minutes
# for the dialog instead of 100s. "Unchanged" in AC3 is about the latency too, not just the silence.
grep -q 'SB_REQUEST_WAIT_TOTAL:-100' "$WAITER" \
  && ok "an attended job session keeps today's 100s default (AC3 — unchanged means the latency too)" \
  || bad "the 900s budget applies to attended boxes too — an operator waits 15min for their dialog"
# Garbage in the env must fall back to the lane DEFAULT, not to the ceiling: "max on garbage" is how
# an attended box would silently inherit the long wait this split exists to keep off it.
grep -q 'TOTAL="\$DEF"' "$WAITER" \
  && ok "a malformed SB_REQUEST_WAIT_TOTAL falls back to the lane default, not to the ceiling" \
  || bad "a malformed budget falls back to CEIL — an attended box inherits the 900s wait"

# ── 2. sandbox: fake HOME, a job context, and a curl that answers polls + records POSTs ──────────
export HOME="$TMP/home"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$TMP/stub"
cp "$WAITER" "$HOME/.local/bin/"; chmod +x "$HOME/.local/bin/sb-await-decision.sh"
printf 'AGENT_TOKEN=sb_test\nAGENT_NAME=test-agent\nPORTAL_URL=http://portal.invalid\n' > "$HOME/.agent-env"
echo '{"session_id":"S"}' > "$HOME/.sidebutton/job-context.json"
: > "$HOME/.sidebutton/unattended"          # base/14 writes this on every install + self-update

cat > "$TMP/stub/curl" <<'CURLEOF'
#!/usr/bin/env bash
# GET  -> logs the URL, answers from $SB_GET_REPLY (after an optional $SB_GET_SLEEP hold).
# POST -> logs the -d body, answers {"ok":true,"resolved":1}. Never touches the network.
is_post=0; body=""; url=""
for ((i=1;i<=$#;i++)); do
  a="${!i}"
  case "$a" in
    -X)    j=$((i+1)); [ "${!j}" = "POST" ] && is_post=1 ;;
    -d)    j=$((i+1)); body="${!j}" ;;
    http*) url="$a" ;;
  esac
done
if [ "$is_post" = 1 ]; then
  printf '%s\n' "$body" >> "$POST_LOG"; printf '{"ok":true,"resolved":1}'; exit 0
fi
printf '%s\n' "$url" >> "$GET_LOG"
[ -n "${SB_GET_SLEEP:-}" ] && sleep "$SB_GET_SLEEP"
[ -n "${SB_GET_REPLY:-}" ] && printf '%s' "$SB_GET_REPLY"
exit 0
CURLEOF
chmod +x "$TMP/stub/curl"
export GET_LOG="$TMP/get.log" POST_LOG="$TMP/post.log"

# Fire the waiter exactly as Claude Code does: hook JSON on stdin, a bare environment, nothing else.
# $1=stdin JSON  $2..=extra KEY=VAL for the child. Captures stdout in $OUT, rc in $RC.
fire() {
  local in="$1"; shift
  : > "$GET_LOG"; : > "$POST_LOG"
  OUT=$(printf '%s' "$in" | env -i PATH="$TMP/stub:$PATH" HOME="$HOME" \
          GET_LOG="$GET_LOG" POST_LOG="$POST_LOG" "$@" \
          bash "$HOME/.local/bin/sb-await-decision.sh" 2>/dev/null)
  RC=$?
}
gets()  { wc -l < "$GET_LOG"  | tr -d ' '; }
posts() { wc -l < "$POST_LOG" | tr -d ' '; }

# A question whose second option is the one ops marks as the default.
Q_MARKED='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion",
  "tool_use_id":"toolu_q1","tool_input":{"questions":[{"question":"Merge the stacked PR into main now?",
  "header":"Merge","options":[{"label":"Merge now"},{"label":"Retarget children first (Recommended)"}]}]}}'
# Options as BARE STRINGS — the shape that silently kills the sibling capture helper today.
Q_STRINGS='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion",
  "tool_use_id":"toolu_q2","tool_input":{"questions":[{"question":"Which DB?",
  "options":["Postgres","SQLite (Recommended)"]}]}}'
# No options at all — there is no default to take, so there is nothing to decide.
Q_NONE='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion",
  "tool_use_id":"toolu_q3","tool_input":{"questions":[{"question":"Describe the failure"}]}}'
PLAN='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"ExitPlanMode",
  "tool_use_id":"toolu_p1","tool_input":{"plan":"Step 1 refactor. Step 2 ship."}}'

OPEN='{"requestKey":"S:toolu_q1","kind":"question","status":"open","answer":null}'

# ── 3. THE BUG: an unanswered question on an unattended job ends in a decision ───────────────────
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
[ -n "$OUT" ] && ok "expiry on an unattended job emits a decision (it used to emit nothing at all)" \
  || bad "expiry still writes zero bytes — Claude Code reads that as 'proceed' and renders the dialog"
echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
                     and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "the decision is a PreToolUse deny — which is what suppresses the desktop dialog" \
  || bad "not a PreToolUse deny: $OUT"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext
                     | test("Retarget children first \\(Recommended\\)")' >/dev/null 2>&1 \
  && ok "the auto-picked option is carried in additionalContext (the channel the model honours)" \
  || bad "additionalContext does not name the recommended option: $OUT"
# The one-field correction the QA pass measured: a bare deny reason is refused as an instruction
# arriving through tool output, and the model turns back to a human — worse than no relay at all.
echo "$OUT" | jq -e '(.hookSpecificOutput.permissionDecisionReason // "")
                     | test("Retarget children first") | not' >/dev/null 2>&1 \
  && ok "the steer is NOT smuggled in permissionDecisionReason alone (measured refused, n=4)" \
  || bad "the choice rides the deny reason — the channel the model rejects: $OUT"
[ "$RC" = 0 ] && ok "still exits 0 (a non-zero hook rc is a different, louder failure mode)" \
  || bad "exit code was $RC, expected 0"

# AC4 — a denied tool call fires NO PostToolUse hook, so the capture helper's resolve never runs.
# If the waiter does not close the row itself, the Needs-you row outlives the prompt.
[ "$(posts)" -ge 1 ] && ok "the waiter POSTs its own resolve when it auto-decides (AC4)" \
  || bad "no resolve POST — the agent_requests row would stay 'open' for the rest of the session"
RES=$(tail -1 "$POST_LOG")
echo "$RES" | jq -e '.action == "resolve" and .session_id == "S" and .tool_use_id == "toolu_q1"
                     and .kind == "question"' >/dev/null 2>&1 \
  && ok "the resolve is keyed to this prompt (session_id + tool_use_id + kind)" \
  || bad "resolve body is wrong: $RES"
echo "$RES" | jq -e '.answer | test("Retarget children first")' >/dev/null 2>&1 \
  && ok "the resolve records WHAT was auto-chosen, so the portal row is not a mystery" \
  || bad "the resolve carries no answer: $RES"

# ── 4. the picker: bare-string options, and no options at all ────────────────────────────────────
fire "$Q_STRINGS" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("SQLite \\(Recommended\\)")' >/dev/null 2>&1 \
  && ok "options given as bare strings are picked correctly (.label on a string THROWS in jq)" \
  || bad "bare-string options were not handled: $OUT"

# The marker is a CONVENTION, not a guarantee — AskUserQuestion asks for it only "if you recommend
# a specific option", so most real prompts carry none. The hook must still decide (AC1), but it must
# not tell the model, or the audit row, that it took a marked option when it took the first one.
Q_UNMARKED='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion",
  "tool_use_id":"toolu_q4","tool_input":{"questions":[{"question":"Merge now?",
  "options":[{"label":"Merge now"},{"label":"Abort"}]}]}}'
fire "$Q_UNMARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("Merge now")' >/dev/null 2>&1 \
  && ok "an unmarked prompt is still decided — on the first option (AC1 holds for most real prompts)" \
  || bad "an unmarked prompt was left to hang: $OUT"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("FIRST option")' >/dev/null 2>&1 \
  && ok "…and the steer says it was the FIRST option, not a marked one (no invented recommendation)" \
  || bad "the steer claims a (Recommended) marker the prompt never carried: $OUT"
echo "$(tail -1 "$POST_LOG")" | jq -e '.answer | test("first option")' >/dev/null 2>&1 \
  && ok "…and the row records the same, so the audit trail is not a fiction" \
  || bad "the row claims a marked option: $(tail -1 "$POST_LOG")"

fire "$Q_NONE" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
[ -z "$OUT" ] && ok "a question with NO options falls through silently — never decide on uncertainty" \
  || bad "invented a decision for an optionless question: $OUT"
[ "$(posts)" = 0 ] && ok "…and closes no row, because it decided nothing" \
  || bad "resolved a row it never answered"

# ── 5. the opt-outs: an attended box keeps today's behaviour exactly ─────────────────────────────
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3 SB_UNATTENDED=0
[ -z "$OUT" ] && ok "SB_UNATTENDED=0 restores the silent fallthrough (explicit env wins)" \
  || bad "SB_UNATTENDED=0 was ignored: $OUT"
touch "$HOME/.sidebutton/attended"
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
[ -z "$OUT" ] && ok "~/.sidebutton/attended restores the silent fallthrough (operator-driven box)" \
  || bad "the attended marker was ignored: $OUT"
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3 SB_UNATTENDED=1
[ -n "$OUT" ] && ok "SB_UNATTENDED=1 arms it again even with the attended marker present" \
  || bad "SB_UNATTENDED=1 was ignored"
# The lane split changed the DEFAULT only — an explicit budget still wins on an attended box, and
# that box still polls for the operator's portal answer for exactly as long as it is told to.
START_T=$SECONDS
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3 SB_UNATTENDED=0
{ [ -z "$OUT" ] && [ $((SECONDS - START_T)) -lt 30 ] && [ "$(gets)" -ge 1 ]; } \
  && ok "an attended box still honours an explicit budget, then falls through silently" \
  || bad "an explicit budget was ignored on an attended box: out='$OUT' polls=$(gets)"
rm -f "$HOME/.sidebutton/attended"

# base/14 must actually WRITE the marker, or the whole lane is dead code on every real box.
grep -q 'SB_MARK_DIR/unattended' "$HOOK" \
  && ok "base/14 installs ~/.sidebutton/unattended (so the fix is armed on provision + self-update)" \
  || bad "nothing writes the unattended marker — the auto-decide could never fire in prod"
grep -q 'SB_MARK_DIR/attended' "$HOOK" \
  && ok "…and never re-creates it once ~/.sidebutton/attended exists (an opt-out survives self-update)" \
  || bad "the install would clobber an operator's opt-out on the next sb-self-update"
grep -q '^14-claude-stop-hook.sh$' "$BASE/refresh-manifest.txt" \
  && ok "14-claude-stop-hook.sh is in refresh-manifest.txt (reaches the fleet via sb-self-update)" \
  || bad "not in refresh-manifest.txt — existing boxes would never get this"

# ── 6. an operator answer inside the budget still wins (AC2) ─────────────────────────────────────
ANSWERED='{"requestKey":"S:toolu_q1","kind":"question","status":"resolved","answer":"Merge now"}'
fire "$Q_MARKED" SB_GET_REPLY="$ANSWERED" SB_REQUEST_WAIT_TOTAL=30
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"
                     and (.hookSpecificOutput.additionalContext | test("Merge now"))' >/dev/null 2>&1 \
  && ok "an operator answer is relayed on additionalContext too, not just the deny reason (AC2)" \
  || bad "the answered path does not steer: $OUT"
[ "$(gets)" = 1 ] && ok "…and returns on the FIRST poll, well inside the budget" \
  || bad "took $(gets) polls to notice an answer that was there immediately"
[ "$(posts)" = 0 ] && ok "…and posts no resolve, because the operator's own resolve already closed it" \
  || bad "double-resolved a row the operator had already closed"

# A row resolved on the desktop with no answer must stay a fallthrough, not become a decision.
CLOSED='{"requestKey":"S:toolu_q1","kind":"question","status":"resolved","answer":null}'
fire "$Q_MARKED" SB_GET_REPLY="$CLOSED" SB_REQUEST_WAIT_TOTAL=30
[ -z "$OUT" ] && ok "a row closed on the desktop (resolved, no answer) still falls through silently" \
  || bad "invented a decision for a desktop-resolved row: $OUT"

# ── 7. ExitPlanMode: the same hang, the same fix ─────────────────────────────────────────────────
fire "$PLAN" SB_GET_REPLY='{"requestKey":"S:toolu_p1","kind":"plan","status":"open","answer":null}' \
     SB_REQUEST_WAIT_TOTAL=3
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"
                     and (.hookSpecificOutput.additionalContext | test("unattended"))' >/dev/null 2>&1 \
  && ok "an unanswered plan prompt is approved rather than left on a dialog nobody will click" \
  || bad "plan expiry did not resolve: $OUT"
[ "$(posts)" -ge 1 ] && ok "…and closes its own row too" || bad "plan auto-approve left the row open"

# ── 8. the invariants that must survive all of the above ────────────────────────────────────────
FOREIGN='{"hook_event_name":"PreToolUse","session_id":"OTHER","tool_name":"AskUserQuestion",
  "tool_use_id":"toolu_x","tool_input":{"questions":[{"question":"q","options":["a (Recommended)"]}]}}'
fire "$FOREIGN" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
{ [ -z "$OUT" ] && [ "$(gets)" = 0 ]; } \
  && ok "a foreign session exits immediately, silent, with ZERO polls (job-session gate holds)" \
  || bad "a non-job session was served: out='$OUT' polls=$(gets)"

mv "$HOME/.agent-env" "$TMP/env.bak"
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
{ [ -z "$OUT" ] && [ "$(gets)" = 0 ]; } \
  && ok "no credentials => silent, no traffic, no decision" \
  || bad "acted without credentials: out='$OUT' polls=$(gets)"
mv "$TMP/env.bak" "$HOME/.agent-env"

fire "$Q_MARKED" SB_GET_REPLY='<html>502 Bad Gateway</html>' SB_REQUEST_WAIT_TOTAL=3
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "an unparseable portal body is treated as 'no answer', then auto-decided at expiry" \
  || bad "a garbage body derailed the waiter: $OUT"
# THE POLL STORM: the old loop slept only when the response was EMPTY, so any fast non-resolved 200
# spun at ~50-100 req/s — ~5,000 requests per blocked prompt at the old budget, ~90,000 at the new.
if [ "$(gets)" -le 6 ]; then
  ok "the loop backs off on EVERY iteration: $(gets) polls in a 3s budget, not hundreds"
else
  bad "poll storm: $(gets) polls in a 3s budget — the back-off is still empty-response-only"
fi

# A zero budget runs no poll at all, so the portal is never asked. Before KAN-204 that meant "do not
# block this prompt"; turning it into "auto-answer it" would be deciding on uncertainty by definition.
fire "$Q_MARKED" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=0
{ [ -z "$OUT" ] && [ "$(gets)" = 0 ] && [ "$(posts)" = 0 ]; } \
  && ok "a 0 budget falls through silently and decides nothing (it asked nobody)" \
  || bad "a 0 budget auto-decided off zero polls: out='$OUT' polls=$(gets) posts=$(posts)"

# stdin the hook must ignore outright.
for junk in '' 'not json' '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"AskUserQuestion"}' \
            '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash"}'; do
  fire "$junk" SB_GET_REPLY="$OPEN" SB_REQUEST_WAIT_TOTAL=3
  { [ -z "$OUT" ] && [ "$RC" = 0 ] && [ "$(gets)" = 0 ]; } \
    || bad "non-applicable stdin was acted on: '${junk:0:40}' -> out='$OUT' rc=$RC polls=$(gets)"
done
ok "empty / malformed / PostToolUse / non-matching-tool stdin: silent, rc 0, no traffic"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
