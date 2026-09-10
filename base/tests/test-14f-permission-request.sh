#!/usr/bin/env bash
# base/tests/test-14f-permission-request.sh — regression guard for KAN-203: the needs-input row a
# `permission_prompt` Notification opens must name ONE gate, say what that gate is asking to allow,
# and never duplicate a prompt the operator already has a row for.
#
# Prod evidence (2026-08-21 / 2026-09-09): Claude Code hard-gates statically-unresolvable `rm`
# targets with an approval that `--dangerously-skip-permissions` cannot grant, so a job session sat
# blocked for 26.9 minutes until a human clicked on the Live desktop. Meanwhile 20 of 22
# `kind=permission` rows in the portal were shadows of an AskUserQuestion prompt that already had
# its own row, and every gate a session raised collapsed onto the CONSTANT `notif-permission` key —
# so a second gate replaced the first one's payload and INHERITED its `answer`. That last one is a
# safety hazard, not an annoyance: a waiter reads `answer` before `status`, so it would replay an
# operator's old Allow onto a destructive command no human ever saw.
#
# The three properties this guard pins, all on the WRITE side (the portal keeps the render-time
# rule as a belt, and neither can drift into being the only defence):
#   1. one gate  -> one key, derived from the in-flight tool_use_id      (KAN-203 AC3)
#   2. a shadow of a question/plan prompt -> no post at all              (KAN-203 AC1)
#   3. the row carries the tool name and the command line                (the QA walk's D5)
# Plus the pre-existing duties of the two helpers involved, because the in-flight stash rides on
# sb-mark-tool-use.sh — the hook that also feeds liveness and SCRUM-1973 commit attribution.
#
# Every case drives the REAL shipped code: the helpers are extracted from base/14's heredocs, and
# the bodies asserted below are what a live box would POST. Isolated: fake HOME, stubbed `curl`
# (argv recorder — no network, no portal row), no real ~/.sidebutton.
# Needs bash + jq. Run: bash base/tests/test-14f-permission-request.sh

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

# `command -v` probes the OUTER PATH; the helpers below are fired under `env -i` with the sandbox
# PATH, so the two must agree or ~15 assertions false-fail on a host whose jq is outside /usr/bin
# (Homebrew, asdf, a source build). Hence PATH="$TMP/stub:$PATH" in fire() rather than a fixed list.
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — every assertion below needs it"
  # NOT a bare `exit 0`: the bash -n above may already have set fail=1, and run-all.sh reads only
  # the exit code, so that would report PASS for a base/14 that does not parse.
  echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── the wiring both halves of the stash depend on ────────────────────────────────────────────────
# The stash is written by the PreToolUse `.*` firing and cleared by the PostToolUse one. Lose either
# and a permission row silently reverts to the un-keyed, contentless shape this ticket fixed.
jq -e '.hooks.PreToolUse[] | select(.matcher==".*") | .hooks[]
       | select(.command | test("sb-mark-tool-use\\.sh"))' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json fires sb-mark-tool-use.sh on PreToolUse .* (writes the in-flight stash)" \
  || bad "no PreToolUse .* entry for sb-mark-tool-use.sh — no gate could ever be identified"
jq -e '.hooks.PostToolUse[] | select(.matcher==".*") | .hooks[]
       | select(.command | test("sb-mark-tool-use\\.sh"))' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json fires it on PostToolUse .* (clears the stash)" \
  || bad "no PostToolUse .* entry — a finished call would keep labelling later gates"
jq -e '.hooks.Notification[] | .hooks[] | select(.command | test("sb-post-request\\.sh"))' \
  "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json still fires sb-post-request.sh on Notification (the capture)" \
  || bad "no Notification entry for sb-post-request.sh — permission gates would be invisible"

# ── extract the real helpers out of the installer heredocs ───────────────────────────────────────
extract() {  # $1=basename  $2=heredoc marker
  awk "/cat > .*$1.*<<'$2'/{f=1;next} /^$2\$/{f=0} f" "$HOOK" > "$TMP/$1"
  [ -s "$TMP/$1" ] || { bad "could not extract $1 from base/14 (heredoc marker $2 moved?)"; return 1; }
  bash -n "$TMP/$1" && ok "bash -n: $1 (the heredoc body really parses)" \
    || bad "$1 does not parse — a live agent would die on every tool call"
}
extract sb-mark-tool-use.sh TUEOF || { echo; echo "FAILURES: 1"; exit 1; }
extract sb-post-request.sh   PREOF || { echo; echo "FAILURES: 1"; exit 1; }

# ── sandbox: fake HOME, a job context, and a curl that records the POSTed body ───────────────────
export HOME="$TMP/home"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$TMP/stub"
cp "$TMP/sb-mark-tool-use.sh" "$TMP/sb-post-request.sh" "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin"/*.sh
printf 'AGENT_TOKEN=sb_test\nAGENT_NAME=test-agent\nPORTAL_URL=http://portal.invalid\n' > "$HOME/.agent-env"
echo '{"session_id":"S"}' > "$HOME/.sidebutton/job-context.json"

cat > "$TMP/stub/curl" <<'CURLEOF'
#!/usr/bin/env bash
# Records the -d body one JSON per line. Never touches the network.
for ((i=1;i<=$#;i++)); do
  if [ "${!i}" = "-d" ]; then j=$((i+1)); printf '%s\n' "${!j}" >> "$CURL_LOG"; fi
done
exit 0
CURLEOF
chmod +x "$TMP/stub/curl"
export CURL_LOG="$TMP/curl.log"

# Fire a helper exactly as Claude Code does: hook JSON on stdin, a bare environment, nothing else.
# The capture forwarder BACKGROUNDS its curl, so give the child a moment to land in the log.
fire() { printf '%s' "$2" | env -i PATH="$TMP/stub:$PATH" HOME="$HOME" CURL_LOG="$CURL_LOG" \
           bash "$HOME/.local/bin/$1"; }
post() { : > "$CURL_LOG"; fire "$1" "$2"; for _ in 1 2 3 4 5 6 7 8 9 10; do
           [ -s "$CURL_LOG" ] && break; sleep 0.1; done; }
posts() { [ -f "$CURL_LOG" ] && wc -l < "$CURL_LOG" | tr -d ' ' || echo 0; }
body()  { tail -1 "$CURL_LOG"; }

PRE_RM='{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_01RM",
         "tool_input":{"command":"export H=$S/h6; rm -rf $H"}}'
NOTIF='{"hook_event_name":"Notification","session_id":"S","notification_type":"permission_prompt",
        "message":"Claude needs your permission to use Bash","title":"Claude Code"}'

# ── 1. the genuine gate: identified, and it says what it is ──────────────────────────────────────
# One record per LIVE CALL, named by the tool_use_id. A single per-session slot was last-writer-wins
# and Claude runs up to CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY (10) calls at once, so section 1b below
# is the case that actually matters on a real box.
inflight() { printf '%s' "$HOME/.sidebutton/inflight-tool-S-$1.json"; }
nflight()  { set -- "$HOME/.sidebutton"/inflight-tool-S-*.json; [ -e "$1" ] && echo $# || echo 0; }
fire sb-mark-tool-use.sh "$PRE_RM"
STASH="$(inflight toolu_01RM)"
[ -s "$STASH" ] && ok "PreToolUse records the in-flight call (inflight-tool-<session>-<tool_use_id>.json)" \
  || bad "no in-flight record written — the gate cannot be identified"
jq -e '.tool_use_id == "toolu_01RM" and .tool_name == "Bash" and (.command | test("rm -rf"))
       and ((.ts | tonumber) > 0)' "$STASH" >/dev/null 2>&1 \
  && ok "the record carries tool_use_id + tool_name + command + a write timestamp" \
  || bad "record contents wrong: $(cat "$STASH" 2>/dev/null)"
# It can hold a raw command line, so it must not be world-readable — every other credential-bearing
# writer in this repo creates 0600 (base/19-secrets.sh:66).
[ "$(stat -c '%a' "$STASH" 2>/dev/null)" = 600 ] \
  && ok "the record is created 0600 (it can carry an inline token)" \
  || bad "record mode is $(stat -c '%a' "$STASH" 2>/dev/null), expected 600"

post sb-post-request.sh "$NOTIF"
[ "$(posts)" = 1 ] || bad "a genuine gate must post exactly one open (got $(posts))"
B1="$(body)"
echo "$B1" | jq -e '.tool_use_id == "notif-permission-toolu_01RM"' >/dev/null 2>&1 \
  && ok "the row is keyed to the GATE (notif-permission-<tool_use_id>), not the constant" \
  || bad "wrong tool_use_id: $(echo "$B1" | jq -c '.tool_use_id' 2>/dev/null)"
echo "$B1" | jq -e '.tool_use_id != "notif-permission"' >/dev/null 2>&1 \
  && ok "the constant notif-permission key is gone (it collapsed every gate onto one row)" \
  || bad "still posting the constant key — two gates would share one row and one answer"
echo "$B1" | jq -e '.kind == "permission" and .action == "open" and .session_id == "S"' >/dev/null 2>&1 \
  && ok "still an open/permission capture for this session" \
  || bad "the capture envelope changed: $B1"
echo "$B1" | jq -e '.payload.tool == "Bash" and (.payload.command | test("rm -rf"))' >/dev/null 2>&1 \
  && ok "the payload names the tool AND the command — Allow is no longer an invisible click" \
  || bad "payload lacks tool/command: $(echo "$B1" | jq -c '.payload' 2>/dev/null)"
echo "$B1" | jq -e '.payload.message | test("permission to use Bash")' >/dev/null 2>&1 \
  && ok "the notification message is still carried" \
  || bad "the message was dropped: $(echo "$B1" | jq -c '.payload' 2>/dev/null)"

# ── 2. two gates in one session are two rows (KAN-203 AC3) ───────────────────────────────────────
# The PostToolUse of gate 1 lands first — that is the ordinary sequence, and it must not leave the
# finished call behind to mislabel gate 2.
fire sb-mark-tool-use.sh '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_01RM"}'
# `! -e`, not `! -s`: an empty file and a file that was never written are the same to `-s`, so the
# weaker test also printed ok when the write itself had silently failed.
[ -e "$STASH" ] && bad "the tool's own PostToolUse must remove its in-flight record" \
  || ok "PostToolUse removes the record for its own tool_use_id"
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Write","tool_use_id":"toolu_02WR","tool_input":{"file_path":"/etc/hosts"}}'
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"permission_prompt","message":"Claude needs your permission to use Write","title":"Claude Code"}'
B2="$(body)"
K1="$(echo "$B1" | jq -r '.tool_use_id')"; K2="$(echo "$B2" | jq -r '.tool_use_id')"
[ -n "$K2" ] && [ "$K1" != "$K2" ] \
  && ok "a second gate in the same session gets its OWN key ($K1 vs $K2)" \
  || bad "two gates still collapse onto one key ($K1)"
echo "$B2" | jq -e '.payload.tool == "Write" and .payload.command == "/etc/hosts"' >/dev/null 2>&1 \
  && ok "gate 2 describes ITSELF (a Write target, not the previous rm)" \
  || bad "gate 2 payload wrong: $(echo "$B2" | jq -c '.payload' 2>/dev/null)"

# A re-fired notification for the SAME gate must stay ONE row, or the operator gets a new row every
# time the CLI re-notifies about a prompt nobody has answered yet. Re-fire the notification for the
# gate that is ACTUALLY held (Write) — firing the Bash fixture here instead asserted that a NEW Bash
# gate may be keyed and labelled as the previous Write call, i.e. it pinned the mislabelling bug.
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"permission_prompt","message":"Claude needs your permission to use Write","title":"Claude Code"}'
[ "$(echo "$(body)" | jq -r '.tool_use_id')" = "notif-permission-toolu_02WR" ] \
  && ok "a re-fired notification for one gate is idempotent (same key, an upsert)" \
  || bad "a re-fire changed the key — the operator would collect duplicate rows"

# ── 1b. CONCURRENCY — the case a single per-session slot got wrong ────────────────────────────────
# Claude issues tool calls in parallel (up to CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY, default 10), and
# the notification names only the TOOL. So the gate must be found by matching that tool against the
# live records — never by "whatever wrote last", which showed the operator a sibling's command while
# the dialog held an `rm -rf`, and collapsed two concurrent gates onto one key.
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_10RM","tool_input":{"command":"rm -rf /data/prod"}}'
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Read","tool_use_id":"toolu_11RD","tool_input":{"file_path":"/etc/motd"}}'
[ "$(nflight)" = 2 ] && ok "two concurrent calls keep two records (not one shared slot)" \
  || bad "concurrent calls collapsed onto $(nflight) record(s)"
post sb-post-request.sh "$NOTIF"
BC="$(body)"
echo "$BC" | jq -e '.tool_use_id == "notif-permission-toolu_10RM"
                    and .payload.tool == "Bash" and (.payload.command | test("/data/prod"))' >/dev/null 2>&1 \
  && ok "a gate in a parallel batch is keyed+labelled from the GATED call, not the last one to start" \
  || bad "mislabelled from a sibling: $(echo "$BC" | jq -c '{tool_use_id,payload}' 2>/dev/null)"

# The sibling finishing must not take the held gate's context with it. With a shared slot the
# sibling's own PostToolUse legitimately truncated the file, reverting the row to a contentless one.
fire sb-mark-tool-use.sh '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"Read","tool_use_id":"toolu_11RD"}'
post sb-post-request.sh "$NOTIF"
echo "$(body)" | jq -e '.tool_use_id == "notif-permission-toolu_10RM" and (.payload.command | test("/data/prod"))' >/dev/null 2>&1 \
  && ok "a sibling completing leaves the held gate's record intact" \
  || bad "the sibling's completion destroyed the gate's context: $(body)"

# Two concurrent calls on the SAME tool are genuinely ambiguous: the box cannot tell which one the
# dialog holds. Degrade honestly — name the tool, omit the command. A confident lie is worse: the
# operator would be shown `rm -rf /a` while approving `rm -rf /b`.
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_12A","tool_input":{"command":"rm -rf /a"}}'
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_13B","tool_input":{"command":"rm -rf /b"}}'
post sb-post-request.sh "$NOTIF"
echo "$(body)" | jq -e '.payload.tool == "Bash" and (.payload | has("command") | not)' >/dev/null 2>&1 \
  && ok "an ambiguous gate names the tool and omits the command rather than guessing" \
  || bad "guessed one of two concurrent same-tool calls: $(echo "$(body)" | jq -c '.payload' 2>/dev/null)"

# A record left behind by a call that never reached PostToolUse — a prompt-deny, an Esc interrupt, a
# thrown error: none of them fire it, and PostToolUseFailure/PermissionDenied are not wired — must
# not be believed hours later. `ts` is what bounds that.
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_14OLD","tool_input":{"command":"rm -rf /stale"}}'
OLDF="$(inflight toolu_14OLD)"
jq -c --arg ts "$(( $(date +%s) - 1200 ))" '.ts = $ts' "$OLDF" > "$OLDF.t" && mv "$OLDF.t" "$OLDF"
post sb-post-request.sh "$NOTIF"
echo "$(body)" | jq -e '(.payload | has("command") | not) and .tool_use_id != "notif-permission-toolu_14OLD"' >/dev/null 2>&1 \
  && ok "a stale record (a denied/interrupted call) is ignored, not read as the live gate" \
  || bad "a 20-minute-old record was used: $(body)"

# ── 1c. the shadow rule is decided from the NOTIFICATION, not from the records ────────────────────
# The notification names the gated tool; that is the only fact that comes from the gate itself.
# Deciding it from a record instead was wrong in both directions — a prompt tool left behind by the
# designed deny-answer path (which fires no PostToolUse) silenced genuine gates.
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion","tool_use_id":"toolu_15ASK","tool_input":{"questions":[{"question":"q","options":[{"label":"x"}]}]}}'
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_16RM","tool_input":{"command":"rm -rf /genuine"}}'
post sb-post-request.sh "$NOTIF"
echo "$(body)" | jq -e '.tool_use_id == "notif-permission-toolu_16RM" and (.payload.command | test("/genuine"))' >/dev/null 2>&1 \
  && ok "a genuine gate is captured even while a prompt tool is also in flight (never dropped)" \
  || bad "a genuine gate was suppressed by an unrelated in-flight prompt: $(body)"

# ── 3. the shadow of a prompt that already has a row (KAN-203 AC1) ───────────────────────────────
for pair in 'AskUserQuestion toolu_03ASK' 'ExitPlanMode toolu_04PLN'; do
  set -- $pair
  fire sb-mark-tool-use.sh "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"S\",\"tool_name\":\"$1\",\"tool_use_id\":\"$2\"}"
  post sb-post-request.sh "{\"hook_event_name\":\"Notification\",\"session_id\":\"S\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use $1\",\"title\":\"Claude Code\"}"
  [ "$(posts)" = 0 ] \
    && ok "a permission notification raised while $1 is in flight posts NOTHING (the +106s shadow)" \
    || bad "still posting a shadow row for $1: $(body)"
  fire sb-mark-tool-use.sh "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"S\",\"tool_name\":\"$1\",\"tool_use_id\":\"$2\"}"
done

# ── 4. degrade, never break ──────────────────────────────────────────────────────────────────────
# No record at all (a fresh box, a cleared ~/.sidebutton, a gate raised outside any tool call): the
# row must still open — a blocked agent stays visible — with today's minimal payload.
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
post sb-post-request.sh "$NOTIF"
B3="$(body)"
[ "$(posts)" = 1 ] && ok "with no record the gate is STILL captured (a blocked agent stays visible)" \
  || bad "no record silently dropped the capture — worse than the bug being fixed"
# The key must be STABLE per gate (AC1: one block, one row) and DISTINCT across gates (AC3). A bare
# epoch is neither: two gates in the same second collapse onto one row, and one unanswered gate
# mints a fresh row on every re-notification. With a tool name but no usable record, the TOOL is
# both — so this asserts the tool key, and that a re-fire does not mint a second row.
echo "$B3" | jq -e '.tool_use_id == "notif-permission-Bash"' >/dev/null 2>&1 \
  && ok "the no-record fallback keys by TOOL — stable per gate, distinct across tools" \
  || bad "fallback key wrong: $(echo "$B3" | jq -c '.tool_use_id' 2>/dev/null)"
post sb-post-request.sh "$NOTIF"
[ "$(echo "$(body)" | jq -r '.tool_use_id')" = "notif-permission-Bash" ] \
  && ok "…and a re-fire on that path is idempotent too (an epoch key flooded rows here)" \
  || bad "the fallback key drifted on re-fire: $(echo "$(body)" | jq -r '.tool_use_id')"
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"permission_prompt","message":"Claude needs your permission to use Write","title":"Claude Code"}'
[ "$(echo "$(body)" | jq -r '.tool_use_id')" = "notif-permission-Write" ] \
  && ok "…and a gate on a different tool still gets its own row on that path" \
  || bad "two different tools shared the fallback key: $(echo "$(body)" | jq -r '.tool_use_id')"
echo "$B3" | jq -e 'has("payload") and (.payload | has("command") | not)' >/dev/null 2>&1 \
  && ok "with nothing to correlate, the payload omits the command rather than inventing one" \
  || bad "payload should carry no command: $(echo "$B3" | jq -c '.payload' 2>/dev/null)"

# A command spanning several lines must not desynchronise the reader's line protocol — and must not
# be REWRITTEN on the way. A bash newline is a statement separator, so `; ` is faithful; collapsing
# all whitespace silently altered the command the operator is asked to approve (the double space
# inside the quoted pattern below is part of it).
rm -f "$HOME/.sidebutton"/inflight-tool-S-*.json
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_05NL","tool_input":{"command":"grep -c '"'"'a  b'"'"' f\nrm -rf ./tmpdir\n"}}'
post sb-post-request.sh "$NOTIF"
B4="$(body)"
echo "$B4" | jq -e '.tool_use_id == "notif-permission-toolu_05NL"
                    and .payload.command == "grep -c '"'"'a  b'"'"' f; rm -rf ./tmpdir"' >/dev/null 2>&1 \
  && ok "a multi-line command is carried on one line, faithfully, and keys the row correctly" \
  || bad "the command was mangled or the capture broke: $(echo "$B4" | jq -c '.payload.command' 2>/dev/null)"

# An unrelated call's PostToolUse must not touch this gate's record — structural now that the
# tool_use_id is in the FILENAME (the clear is an `rm -f`, with no format contract to drift).
fire sb-mark-tool-use.sh '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"Read","tool_use_id":"toolu_99OTHER"}'
jq -e '.tool_use_id == "toolu_05NL"' "$(inflight toolu_05NL)" >/dev/null 2>&1 \
  && ok "a sibling's PostToolUse leaves the held gate recorded (Claude runs tools in parallel)" \
  || bad "a sibling completion erased the in-flight gate"

# Both path components come from stdin JSON and both reach a filesystem path.
BEFORE_OUT="$(ls -1 "$HOME"/.. 2>/dev/null | wc -l)"
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"../../evil","tool_name":"Bash","tool_use_id":"toolu_X","tool_input":{"command":"x"}}'
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"../evil2","tool_input":{"command":"x"}}'
[ "$(ls -1 "$HOME"/.. 2>/dev/null | wc -l)" = "$BEFORE_OUT" ] \
  && ok "a traversal session_id / tool_use_id writes nothing outside ~/.sidebutton" \
  || bad "the charset guard let a record escape: $(ls -1 "$HOME"/.. 2>/dev/null)"

# ── 5. the invariants this helper already had ────────────────────────────────────────────────────
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"OTHER","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
[ "$(posts)" = 0 ] && ok "a NON-job session's gate is still dropped (job-session gate intact)" \
  || bad "a foreign session posted: $(body)"
post sb-post-request.sh '{"hook_event_name":"Notification","session_id":"S","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
[ "$(posts)" = 0 ] && ok "idle_prompt still falls through (the IDLE counter owns it, not Needs-you)" \
  || bad "idle_prompt captured again: $(body)"

# The question / plan lane is untouched — it is the one that already works end to end.
post sb-post-request.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"AskUserQuestion","tool_use_id":"toolu_01ABC","tool_input":{"questions":[{"question":"Which DB?","options":[{"label":"Postgres"},{"label":"SQLite"}]}]}}'
echo "$(body)" | jq -e '.kind == "question" and .tool_use_id == "toolu_01ABC"
                        and .payload.questions[0].question == "Which DB?"
                        and .payload.questions[0].options == ["Postgres","SQLite"]' >/dev/null 2>&1 \
  && ok "AskUserQuestion capture unchanged (key + reduced payload)" \
  || bad "the question capture regressed: $(body)"
post sb-post-request.sh '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"AskUserQuestion","tool_use_id":"toolu_01ABC"}'
echo "$(body)" | jq -e '.action == "resolve" and .tool_use_id == "toolu_01ABC"' >/dev/null 2>&1 \
  && ok "the matching PostToolUse resolve is unchanged" || bad "resolve regressed: $(body)"
post sb-post-request.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"ExitPlanMode","tool_use_id":"toolu_02PLN","tool_input":{"plan":"the plan"}}'
echo "$(body)" | jq -e '.kind == "plan" and .payload.plan == "the plan"' >/dev/null 2>&1 \
  && ok "ExitPlanMode capture unchanged" || bad "the plan capture regressed: $(body)"
post sb-post-request.sh '{"hook_event_name":"Stop","session_id":"S"}'
echo "$(body)" | jq -e '.action == "resolve" and .session_id == "S" and (has("tool_use_id") | not)' >/dev/null 2>&1 \
  && ok "the Stop bulk-resolve is unchanged (still closes the session's open rows)" \
  || bad "the Stop resolve regressed: $(body)"

# ── 6. sb-mark-tool-use.sh's OWN duties, which the stash now rides on ────────────────────────────
# The stash extended this helper's single jq to four values. If that read desynchronises, the two
# signals it has always carried break silently: job liveness, and the SCRUM-1973 commit bracket.
mkdir -p "$HOME/workspace/repo/.git/refs/heads"
echo "ref: refs/heads/main" > "$HOME/workspace/repo/.git/HEAD"
echo "abc123def456" > "$HOME/workspace/repo/.git/refs/heads/main"
rm -f "$HOME/.sidebutton/last-tool-use" "$HOME/.sidebutton/session-branches-S.log"
fire sb-mark-tool-use.sh '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_06","tool_input":{"command":"ls"}}'
[ -f "$HOME/.sidebutton/last-tool-use" ] \
  && bad "PreToolUse stamped liveness — a tool about to run has produced no activity yet" \
  || ok "PreToolUse still does NOT stamp last-tool-use"
grep -q $'\tmain\tabc123def456\tpre\t' "$HOME/.sidebutton/session-branches-S.log" 2>/dev/null \
  && ok "the SCRUM-1973 bracket still records the PRE line (branch + sha + kind + epoch)" \
  || bad "pre bracket missing: $(cat "$HOME/.sidebutton/session-branches-S.log" 2>/dev/null)"
fire sb-mark-tool-use.sh '{"hook_event_name":"PostToolUse","session_id":"S","tool_name":"Bash","tool_use_id":"toolu_06"}'
[ -s "$HOME/.sidebutton/last-tool-use" ] && ok "PostToolUse still stamps last-tool-use (job liveness)" \
  || bad "last-tool-use was not stamped — the monitor would call this box idle"
grep -q $'\tmain\tabc123def456\tpost\t' "$HOME/.sidebutton/session-branches-S.log" 2>/dev/null \
  && ok "the bracket still records the POST line (attribution stays causal)" \
  || bad "post bracket missing: $(cat "$HOME/.sidebutton/session-branches-S.log" 2>/dev/null)"
rm -f "$HOME/.sidebutton/last-tool-use"
fire sb-mark-tool-use.sh '{"hook_event_name":"PostToolUse","session_id":"OTHER","tool_name":"Bash","tool_use_id":"toolu_07"}'
[ -f "$HOME/.sidebutton/last-tool-use" ] \
  && bad "a non-job session stamped job liveness" \
  || ok "a non-job session still cannot stamp liveness, but keeps its own bracket"
[ -s "$HOME/.sidebutton/session-branches-OTHER.log" ] \
  && ok "…and that bracket is written under the FIRING session's own id" \
  || bad "the foreign session's bracket is missing (attribution would blind that session)"

# The janitor has to know about the new file, or per-session stashes accumulate forever on a box
# that runs 12-23 sessions a day. Read into a variable rather than piping into `grep -q`: under
# `pipefail` the early exit of a quiet grep sends awk a SIGPIPE and the pipeline reports 141.
SESSION_START="$(awk "/cat > .*sb-session-start.sh.*<<'SESSIONEOF'/{f=1;next} /^SESSIONEOF\$/{f=0} f" "$HOOK")"
case "$SESSION_START" in
  *"inflight-tool-*.json"*) ok "sb-session-start.sh's janitor sweeps stale inflight-tool-*.json files" ;;
  *) bad "the janitor does not clean inflight-tool-*.json — they would pile up per session" ;;
esac

echo
if [ "$fail" -ne 0 ]; then echo "FAILURES"; exit 1; fi
echo "ALL PASS"
