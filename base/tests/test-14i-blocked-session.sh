#!/usr/bin/env bash
# base/tests/test-14i-blocked-session.sh — regression guard for DEV-51 (SH-1): the blocked session.
#
# A turn that ends on an API error fires StopFailure, never Stop, so a session held by a usage limit
# or a provider error used to look like a running job while it sat on a dialog for hours (three Pull
# repos jobs on the weekly-limit menu, 2026-09-26). This guard pins the agent half of plan §4.12:
#   1. StopFailure opens ONE kind=blocked row — cause, message, auto_continue at the top level, no
#      tool_use_id — with auto_continue true only for a subscription usage limit that names its reset;
#   2. the first capture keeps its raw input once (Claude Code documents no error fields);
#   3. the usage-limit options menu gets "Wait here, then continue automatically" picked by its TEXT,
#      Enter only once the pointer sits on it; a pane without the menu gets no keys; a menu without
#      the row re-opens the row with auto_continue=false; only Down/Up/Enter are ever sent;
#   4. quota_auto_resume_fired and a later Stop resolve the row, _stale presses Enter, _disabled
#      re-opens it with auto_continue=false;
#   5. a non-job session posts nothing and drives nothing;
#   6. the wiring, and autoContinueAtUsageLimit: true in the settings base/09 writes and in the
#      refresh merge that carries it to live boxes.
#
# Every case drives the REAL helpers, extracted from base/14's heredocs, against a stub portal (a
# local HTTP server, fixtures/stub-portal.py) and a stub `tmux` on PATH that renders fixture panes,
# moves the pointer on Down/Up and records every key — no live portal, no real tmux session.
# Needs bash + jq; the POST cases need python3 + curl. Run: bash base/tests/test-14i-blocked-session.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
STUB_PORTAL="$SCRIPT_DIR/fixtures/stub-portal.py"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; return 1; }
skip() { printf 'skip - %s\n' "$1"; }
finish() { echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"; }

bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"
command -v jq >/dev/null 2>&1 || { skip "jq not installed — every assertion below needs it"; finish; }

# ── wiring + settings ──────────────────────────────────────────────────────────────────────────────
jq -e '.hooks.StopFailure[] | select(.matcher == "") | .hooks[]
       | select(.command == "$HOME/.local/bin/sb-post-request.sh")' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json wires StopFailure (every error type: empty matcher) -> sb-post-request.sh" \
  || bad "StopFailure is not wired to sb-post-request.sh — a blocked session stays invisible"
jq -e '.hooks.Stop[] | .hooks[] | select(.command == "$HOME/.local/bin/sb-post-request.sh")' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "…and Stop still fires it (the bulk resolve that closes a blocked row once the session goes on)" \
  || bad "Stop no longer fires sb-post-request.sh"
jq -e '.settings.autoContinueAtUsageLimit == true' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json carries settings.autoContinueAtUsageLimit: true" \
  || bad "the hooks asset does not pin autoContinueAtUsageLimit"

TMP="$(mktemp -d)"
PORTAL_PID=""
cleanup() { [ -n "$PORTAL_PID" ] && kill "$PORTAL_PID" 2>/dev/null && wait "$PORTAL_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# base/09 at provision: run its real settings block (lifted out of the step) against a sandbox.
awk '/^jq -n --slurpfile h "\$BASE_DIR\/assets\/claude-hooks.json"/{f=1} f{print} f && /settings\.json"$/{exit}' \
  "$BASE/09-agent-user.sh" > "$TMP/09-settings.sh"
mkdir -p "$TMP/h09/.claude"
if [ -s "$TMP/09-settings.sh" ] && BASE_DIR="$BASE" AGENT_HOME="$TMP/h09" bash "$TMP/09-settings.sh" 2>/dev/null \
   && jq -e --slurpfile h "$HOOKS_JSON" '.autoContinueAtUsageLimit == true and .skipDangerousModePermissionPrompt == true
        and .env.DISABLE_AUTOUPDATER == "1" and .hooks == $h[0].hooks and (has("settings") | not)' \
        "$TMP/h09/.claude/settings.json" >/dev/null 2>&1; then
  ok "base/09's settings.json carries autoContinueAtUsageLimit: true beside its hooks (and no stray 'settings' key)"
else
  bad "base/09 does not write autoContinueAtUsageLimit: true into ~/.claude/settings.json"
fi
# Live boxes: base/09 never re-runs there, so the refresh merge has to carry the key.
(
  command -v log >/dev/null 2>&1 || log() { :; }
  . "$BASE/lib-refresh.sh"
  export AGENT_HOME="$TMP/hlive" AGENT_USER="$(id -un)"
  mkdir -p "$AGENT_HOME/.claude"
  printf '%s' '{"mcpServers":{"sidebutton":{"type":"sse","url":"http://localhost:9876/sse"}},"env":{"DISABLE_AUTOUPDATER":"1"},
               "timeFormat":"24-hour","autoContinueAtUsageLimit":false,"hooks":{"Stop":[]}}' > "$AGENT_HOME/.claude/settings.json"
  s1="$(_sb_merge_claude_hooks "$HOOKS_JSON")"; s2="$(_sb_merge_claude_hooks "$HOOKS_JSON")"
  if [ "$s1" = updated ] && [ "$s2" = unchanged ] && jq -e --slurpfile h "$HOOKS_JSON" '
       .autoContinueAtUsageLimit == true and .mcpServers.sidebutton.url == "http://localhost:9876/sse"
       and .timeFormat == "24-hour" and .env.DISABLE_AUTOUPDATER == "1" and .hooks == $h[0].hooks
       and (has("settings") | not)' "$AGENT_HOME/.claude/settings.json" >/dev/null 2>&1; then
    echo "ok   - _sb_merge_claude_hooks lands autoContinueAtUsageLimit: true on a live settings.json (keeps mcpServers, timeFormat, env; second run: unchanged)"
  else
    echo "FAIL - the refresh merge does not carry the setting to a live box (status ${s1}/${s2})"; exit 1
  fi
) || fail=1

# ── extract the helpers ────────────────────────────────────────────────────────────────────────────
extract() {  # $1=basename  $2=heredoc marker
  awk "/cat > .*$1.*<<'$2'/{f=1;next} /^$2\$/{f=0} f" "$HOOK" > "$TMP/$1"
  [ -s "$TMP/$1" ] || { bad "could not extract $1 from base/14 (heredoc marker $2 moved?)"; return 1; }
  bash -n "$TMP/$1" && ok "bash -n: $1 (the heredoc body parses)" || bad "$1 does not parse"
}
extract sb-post-request.sh PREOF || finish
extract sb-usage-limit-menu.sh MENUEOF || finish
extract sb-checkpoint-transcript.sh CKPTEOF || finish
grep -q 'chmod +x "$AGENT_HOME/.local/bin/sb-usage-limit-menu.sh"' "$HOOK" \
  && ok "base/14 installs the menu driver executable" || bad "base/14 never chmods sb-usage-limit-menu.sh"

for t in python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { skip "$t not installed — the stub-portal cases need it"; finish; }
done

# ── sandbox: fake HOME, a job context, the stub portal, the stub tmux ───────────────────────────────
export HOME="$TMP/home"
SID="5d0e3c11-8a4b-4c7d-9e2f-1a2b3c4d5e6f"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$TMP/stub" "$TMP/tmux"
cp "$TMP/sb-post-request.sh" "$TMP/sb-usage-limit-menu.sh" "$TMP/sb-checkpoint-transcript.sh" "$HOME/.local/bin/"; chmod +x "$HOME/.local/bin"/*.sh
printf '{"job_id":77,"step_index":0,"session_id":"%s"}\n' "$SID" > "$HOME/.sidebutton/job-context.json"
MODE_FILE="$TMP/portal.mode"; PLOG="$TMP/portal.log"; : > "$PLOG"; echo 200 > "$MODE_FILE"
python3 "$STUB_PORTAL" "$MODE_FILE" "$PLOG" > "$TMP/portal.port" 2>/dev/null &
PORTAL_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/portal.port" ] && break; sleep 0.1; done
PORT="$(head -1 "$TMP/portal.port" 2>/dev/null)"
[ -n "$PORT" ] || { bad "the stub portal did not start"; finish; }
# The driver sources ~/.agent-env itself (its lines are not exported to a child): short budgets here.
printf 'AGENT_TOKEN=sb_test_token\nAGENT_NAME=agent-test\nPORTAL_URL=http://127.0.0.1:%s\nSB_USAGE_MENU_WAIT_SEC=3\nSB_USAGE_MENU_POLL_SEC=1\n' \
  "$PORT" > "$HOME/.agent-env"
LOG="$HOME/.sidebutton/usage-hook.log"; : > "$LOG"

# The stub tmux: one job session, a scene file naming the fixture pane, a pointer that Down/Up move
# (skipping disabled rows, as the CLI's Select does), and a log of every key with its target.
export TMUX_STUB="$TMP/tmux"
cat > "$TMP/stub/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
S="$TMUX_STUB"; cmd="${1:-}"; shift || true; target=""
while [ $# -gt 0 ]; do
  case "$1" in -t) target="$2"; shift 2 ;; -p|-J) shift ;; -S|-E) shift 2 ;; *) break ;; esac
done
name="${target#=}"; name="${name%:}"
live() { [ -n "$name" ] && grep -qxF "$name" "$S/sessions" 2>/dev/null; }
rows() {  # one row per line: "<d|->\t<label>" (d = disabled); $1 = the moment (epoch ms) whose menu is wanted
  local at="${1:-$(date +%s%3N)}"
  case "$(cat "$S/scene" 2>/dev/null)" in
    menu-promo)  # the CLI inserts a promo row once its data loads (2.1.283: toSpliced(1, 0, promo))
      if [ "$at" -lt "$(cat "$S/shift_at" 2>/dev/null || echo 0)" ]; then
        printf -- '-\tStop and wait for limit to reset\n-\tWait here, then continue automatically at 4pm\n'
      else
        printf -- '-\tStop and wait for limit to reset\n-\tClaim a free week of Max\n-\tWait here, then continue automatically at 4pm\n'
      fi ;;
    menu)          printf -- '-\tStop and wait for limit to reset\n-\tWait here, then continue automatically at 4pm\n-\tUpgrade your plan\n' ;;
    menu-disabled) printf -- '-\tStop and wait for limit to reset\nd\tClaim free usage (already claimed)\n-\tWait here, then continue automatically shortly\n' ;;
    menu-noauto)   printf -- '-\tStop and wait for limit to reset\n-\tUpgrade your plan\n' ;;
    menu-armed)    printf -- '-\tStop and wait for limit to reset\n-\tDon\xe2\x80\x99t continue automatically\n' ;;
    menu-nofocus)  printf -- '-\tStop and wait for limit to reset\n-\tWait here, then continue automatically at 4pm\n' ;;
    menu-usage)    printf -- '-\tStop\n-\tAdd funds to continue with usage credits\n-\tUpgrade your plan\n' ;;
  esac
}
render() {
  local scene i=0 focus lab dis n left
  # "<n> <scene>" in scene-next: after n more captures the pane turns into that scene (a menu somebody
  # answered on the desktop, say).
  if [ -s "$S/scene-next" ]; then
    read -r left n < "$S/scene-next"
    if [ "$left" -le 0 ]; then echo "$n" > "$S/scene"; rm -f "$S/scene-next"
    else echo "$((left - 1)) $n" > "$S/scene-next"; fi
  fi
  scene="$(cat "$S/scene" 2>/dev/null)"; focus="$(cat "$S/focus" 2>/dev/null || echo 0)"
  printf '> earlier the model quoted it: Wait here, then continue automatically\n'   # above the dialog: a decoy
  printf '\xe2\x97\x8f API Error: You\x27ve hit your weekly limit \xc2\xb7 resets Sep 29, 4pm (UTC)\n\n'
  case "$scene" in
    menu*)
      printf ' What do you want to do?\n\n'
      while IFS=$'\t' read -r dis lab; do
        if [ "$scene" != menu-nofocus ] && [ "$i" = "$focus" ]; then printf ' \xe2\x9d\xaf %s. %s\n' $((i + 1)) "$lab"
        else printf '   %s. %s\n' $((i + 1)) "$lab"; fi
        i=$((i + 1))
      done < <(rows "$(( $(date +%s%3N) - $(cat "$S/render_lag" 2>/dev/null || echo 0) ))")   # the frame may lag the menu
      printf '\n Enter to confirm \xc2\xb7 Esc to cancel\n' ;;
    stale)  printf '\xe2\x9c\xbb Usage limit has reset \xc2\xb7 press enter to continue\n\n> \n' ;;
    stale-old)  # the words only in old transcript text, well above the live bottom of the screen
      printf 'the docs said: press Enter to continue\n'
      for i in 1 2 3 4 5 6 7 8 9 10; do printf '\xe2\x97\x8f Bash(ls step-%s)\n' "$i"; done
      printf '\xe2\x9c\xbb Working\xe2\x80\xa6 (esc to interrupt)\n\n> \n' ;;
    picked) printf 'Claude Code will continue automatically at 4pm. Keep this session open.\n\n> \n' ;;
    *)      printf '\xe2\x9c\xbb Working\xe2\x80\xa6 (esc to interrupt)\n\n> \n' ;;
  esac
}
move() {  # $1 = +1 | -1 — to the next enabled row, or stay
  local n focus i d
  mapfile -t R < <(rows); n=${#R[@]}; focus="$(cat "$S/focus" 2>/dev/null || echo 0)"; i=$focus
  while :; do
    i=$((i + $1)); [ "$i" -ge 0 ] && [ "$i" -lt "$n" ] || return 0
    d="${R[$i]%%$'\t'*}"; [ "$d" = d ] && continue
    echo "$i" > "$S/focus"; return 0
  done
}
apply_key() {
  case "$1" in
    Down) move 1 ;; Up) move -1 ;;
    Enter) mapfile -t R < <(rows); f="$(cat "$S/focus" 2>/dev/null || echo 0)"
           printf '%s\n' "${R[$f]#*$'\t'}" > "$S/picked"; echo picked > "$S/scene" ;;
  esac
}
# "lag": a key takes effect only lag_ms after it was sent, like a TUI that redraws slowly — every stub call
# first applies the keys that are due, in order.
lag="$(cat "$S/lag_ms" 2>/dev/null || echo 0)"
if [ "$lag" -gt 0 ] && [ -s "$S/queue" ]; then
  now="$(date +%s%3N)"; : > "$S/queue.next"
  while read -r ts key; do
    if [ $((now - ts)) -ge "$lag" ]; then apply_key "$key"; else printf '%s %s\n' "$ts" "$key" >> "$S/queue.next"; fi
  done < "$S/queue"
  mv "$S/queue.next" "$S/queue"
fi
case "$cmd" in
  has-session)  live ;;
  capture-pane) live || exit 1; render ;;
  send-keys)
    live || exit 1
    printf '%s %s\n' "$target" "$*" >> "$S/keys.log"
    printf '%s %s\n' "$target" "$*" >> "$S/all-keys.log"   # never reset: the whole run's keys
    if [ "$lag" -gt 0 ]; then printf '%s %s\n' "$(date +%s%3N)" "$1" >> "$S/queue"; else apply_key "$1"; fi ;;
  *) exit 1 ;;
esac
TMUXEOF
chmod +x "$TMP/stub/tmux"

scene() { echo "$1" > "$TMUX_STUB/scene"; echo "${2:-0}" > "$TMUX_STUB/focus"; : > "$TMUX_STUB/keys.log"
          rm -f "$TMUX_STUB/picked" "$TMUX_STUB/scene-next" "$TMUX_STUB/lag_ms" "$TMUX_STUB/queue" "$TMUX_STUB/shift_at" "$TMUX_STUB/render_lag"; }
echo "sbjob-$SID" > "$TMUX_STUB/sessions"
PATH_S="$TMP/stub:$PATH"
fire() {  # $1 = hook JSON, $2.. = extra env (a provider key for an API-key run)
  local in="$1"; shift
  printf '%s' "$in" | env -i PATH="$PATH_S" HOME="$HOME" TMUX_STUB="$TMUX_STUB" "$@" bash "$HOME/.local/bin/sb-post-request.sh"
}
# A driver still inside its budget holds the per-session lock (the file itself stays behind by design),
# and a second one would leave at once: every direct run first waits until nobody holds it.
quiesce() {
  local f busy
  for _ in $(seq 1 100); do
    busy=0
    for f in "$HOME/.sidebutton"/usage-limit-menu-*.lock; do
      [ -e "$f" ] || continue
      if command -v flock >/dev/null 2>&1; then flock -n "$f" true || busy=1; fi
    done
    [ "$busy" = 0 ] && return 0; sleep 0.1
  done
  return 1
}
drive() { quiesce; env -i PATH="$PATH_S" HOME="$HOME" TMUX_STUB="$TMUX_STUB" bash "$HOME/.local/bin/sb-usage-limit-menu.sh" "$@"; }
posts() { wc -l < "$PLOG" | tr -d ' '; }
wait_posts() { for _ in $(seq 1 40); do [ "$(posts)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
last_body() { tail -1 "$PLOG" | jq -c '.body | fromjson'; }
# A detached driver is finished when it logs one of its closing lines (the raw-pane note comes first).
DONE_RE="picked 'Wait here|no options menu within|re-opened with auto_continue=false|offers only to cancel|tmux session gone|pressed Enter on|no 'press enter to continue'|closed without the driver"
menu_lines() { grep -cE "usage-limit menu .*(${DONE_RE})" "$LOG" 2>/dev/null || true; }
wait_menu_line() { for _ in $(seq 1 100); do [ "$(menu_lines)" -gt "$1" ] && return 0; sleep 0.1; done; return 1; }
keys() { cat "$TMUX_STUB/keys.log" 2>/dev/null; }
LIMIT_LINE="You've hit your weekly limit · resets Sep 29, 4pm (UTC)"
stopfailure() {  # $1 = error type, $2 = last_assistant_message (JSON value), $3 = extra fields
  local extra="${3:-}"; [ -n "$extra" ] || extra='{}'
  jq -nc --arg sid "$SID" --arg err "$1" --argjson msg "$2" --argjson extra "$extra" \
    '{hook_event_name:"StopFailure", session_id:$sid, transcript_path:"/nonexistent.jsonl", cwd:"/home/agent/workspace",
      permission_mode:"bypassPermissions", error:$err, error_details:null, last_assistant_message:$msg} + $extra'
}
notif() { jq -nc --arg sid "$SID" --arg t "$1" --arg m "$2" \
  '{hook_event_name:"Notification", session_id:$sid, notification_type:$t, message:$m, title:"Claude Code"}'; }

# ── 1. StopFailure rate_limit on a subscription run: one blocked row + the menu picked ───────────────
scene menu 0; lines0="$(menu_lines)"
OUT="$(fire "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')")")"
[ -z "$OUT" ] && ok "sb-post-request.sh prints nothing on StopFailure" || bad "stdout on StopFailure: $OUT"
if wait_posts 1; then
  B="$(last_body)"
  [ "$(printf '%s' "$B" | jq -c '{action, kind, session_id, cause, message, auto_continue}')" \
    = "$(jq -nc --arg sid "$SID" --arg m "$LIMIT_LINE" '{action:"open", kind:"blocked", session_id:$sid, cause:"rate_limit", message:$m, auto_continue:true}')" ] \
    && ok "one row: {action:open, kind:blocked, cause:rate_limit, message:<the printed line>, auto_continue:true}" \
    || bad "wrong blocked payload: $B"
  printf '%s' "$B" | jq -e 'has("tool_use_id") | not' >/dev/null && ok "…with no tool_use_id (the portal keys the row <session_id>:blocked)" \
    || bad "the blocked open carries a tool_use_id"
  R="$(tail -1 "$PLOG")"
  [ "$(printf '%s' "$R" | jq -r .path)" = /api/agents/requests ] && [ "$(printf '%s' "$R" | jq -r .headers.authorization)" = "Bearer sb_test_token" ] \
    && ok "POST /api/agents/requests with the agent token" || bad "posted elsewhere / without the token: $R"
else
  bad "StopFailure posted nothing"
fi
if wait_menu_line "$lines0"; then
  [ "$(keys | awk '{print $2}' | paste -sd, -)" = "Down,Enter" ] \
    && ok "the driver the hook started moved Down once, then pressed Enter" || bad "unexpected keys: $(keys | paste -sd'|' -)"
  [ "$(cat "$TMUX_STUB/picked" 2>/dev/null)" = "Wait here, then continue automatically at 4pm" ] \
    && ok "…and Enter landed on 'Wait here, then continue automatically at 4pm' (the pointer checked first)" \
    || bad "Enter picked '$(cat "$TMUX_STUB/picked" 2>/dev/null)'"
  keys | awk -v t="=sbjob-$SID:" '$1 != t {bad=1} END {exit bad}' \
    && ok "every key went to the exact pane =sbjob-<session_id>: (tmux exact-name match)" || bad "a key went to another target: $(keys)"
else
  bad "the driver never finished (no usage-limit menu line in usage-hook.log)"
fi
FIRST="$HOME/.sidebutton/stopfailure-first-input.json"
if [ -f "$FIRST" ] && [ "$(stat -c %a "$FIRST")" = 600 ] && [ "$(jq -r .error "$FIRST")" = rate_limit ]; then
  ok "the first capture's raw input is kept once, 0600 (~/.sidebutton/stopfailure-first-input.json)"
else
  bad "no first-capture record of the raw StopFailure input"
fi

# ── 2. the matrix of auto_continue, message fallbacks and the raw record written once ────────────────
sum_before="$(sha256sum "$FIRST" | cut -c1-64)"
case_auto() {  # $1 = label, $2 = expected auto_continue, $3 = expected message, then the fire args
  local label="$1" want="$2" wantmsg="$3"; shift 3
  local n; n="$(posts)"; scene plain 0
  fire "$@" >/dev/null
  if wait_posts $((n + 1)); then
    B="$(last_body)"
    [ "$(printf '%s' "$B" | jq -r .auto_continue)" = "$want" ] && [ "$(printf '%s' "$B" | jq -r .message)" = "$wantmsg" ] \
      && ok "$label -> auto_continue:$want, message '$wantmsg'" || bad "$label: got $B"
  else
    bad "$label: nothing posted"
  fi
}
BILLING="Credit balance is too low"
case_auto "billing_error on an API-key run" false "$BILLING" \
  "$(stopfailure billing_error "$(jq -n --arg m "$BILLING" '$m')")" ANTHROPIC_API_KEY=sk-ant-test
case_auto "rate_limit on an API-key run (a provider's quota)" false "$LIMIT_LINE" \
  "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')")" ANTHROPIC_API_KEY=sk-ant-test
case_auto "rate_limit on a CCR/gateway run" false "$LIMIT_LINE" \
  "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')")" ANTHROPIC_BASE_URL=http://127.0.0.1:3456
TRANSIENT="API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
case_auto "a subscription rate_limit with no reset (the transient server throttle)" false "$TRANSIENT" \
  "$(stopfailure rate_limit "$(jq -n --arg m "$TRANSIENT" '$m')")"
case_auto "overloaded on a subscription run" false "API Error: Overloaded" \
  "$(stopfailure overloaded '"API Error: Overloaded"')"
RAWBODY='429 {"error":{"message":"rate limited, the window will reset soon"}}'
case_auto "a subscription rate_limit whose only 'reset' is a raw provider body (no printed ' · resets ' anchor)" false "$RAWBODY" \
  "$(stopfailure rate_limit null "$(jq -nc --arg d "$RAWBODY" '{error_details:$d}')")"
# The message fallbacks: error_details when the line is absent; the transcript's last API-error entry
# when both are; the bare cause when nothing is left.
case_auto "no last_assistant_message: error_details is the message" false "429 {\"error\":\"rate\"}" \
  "$(stopfailure rate_limit null '{"error_details":"429 {\"error\":\"rate\"}"}')" ANTHROPIC_API_KEY=sk-ant-test
TRX="$TMP/transcript.jsonl"
{ printf '%s\n' '{"type":"user","message":{"content":"go"}}'
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: an older error"}]}}'
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 7:40pm (Europe/Berlin)"}]}}'
  printf '%s\n' '{"torn": ' ; } > "$TRX"
case_auto "neither field: the transcript's LAST API-error entry (a torn last line tolerated)" true \
  "You've hit your session limit · resets 7:40pm (Europe/Berlin)" \
  "$(stopfailure rate_limit null "$(jq -nc --arg tp "$TRX" '{transcript_path:$tp}')")"
case_auto "nothing at all: the cause itself (a row still opens)" false "unknown" \
  "$(jq -nc --arg sid "$SID" '{hook_event_name:"StopFailure", session_id:$sid}')"
sleep 0.5; quiesce   # the transcript case (auto_continue:true) started a driver on the plain pane
[ "$(sha256sum "$FIRST" | cut -c1-64)" = "$sum_before" ] && ok "the raw first-capture record is written once, never overwritten" \
  || bad "a later StopFailure rewrote the first-capture record"

# ── 3. the menu driver, case by case (run directly; each budget is 3 s) ──────────────────────────────
n="$(posts)"
scene menu 2; drive select "$SID" rate_limit "$LIMIT_LINE"
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Up,Enter" ] && [ "$(cat "$TMUX_STUB/picked" 2>/dev/null)" = "Wait here, then continue automatically at 4pm" ] \
  && ok "pointer BELOW the row: Up once, Enter on the Wait-here row" || bad "pointer below: keys $(keys | paste -sd'|' -)"
scene menu 1; drive select "$SID" rate_limit "$LIMIT_LINE"
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Enter" ] && ok "pointer already ON the row: Enter only, no moves" \
  || bad "pointer on the row: keys $(keys | paste -sd'|' -)"
scene menu-disabled 0; drive select "$SID" rate_limit "$LIMIT_LINE"
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Down,Enter" ] && [ "$(cat "$TMUX_STUB/picked" 2>/dev/null)" = "Wait here, then continue automatically shortly" ] \
  && ok "a disabled row in between: one Down (the menu skips it), re-read, Enter — never a key count from line math" \
  || bad "disabled row: keys $(keys | paste -sd'|' -), picked '$(cat "$TMUX_STUB/picked" 2>/dev/null)'"
quiesce; scene plain 0; t0=$(date +%s); drive select "$SID" rate_limit "$LIMIT_LINE"; t1=$(date +%s)
[ -z "$(keys)" ] && ok "a pane without the menu (reset within 24 h: Claude Code waits by itself) gets NO keys" || bad "keys sent to a plain pane: $(keys)"
[ $((t1 - t0)) -ge 2 ] && [ $((t1 - t0)) -le 6 ] && ok "…and the driver watches for its whole budget, then gives up ($((t1 - t0)) s of 3)" \
  || bad "the driver ran $((t1 - t0)) s against a 3 s budget"
tail -1 "$LOG" | grep -q 'no options menu within 3s' && ok "…logging one line that says so" || bad "no 'no options menu' log line"
scene menu-armed 0; drive select "$SID" rate_limit "$LIMIT_LINE"
[ -z "$(keys)" ] && ok "a menu that offers only \"Don't continue automatically\" (wait armed) gets no keys" || bad "keys on an armed menu: $(keys)"
sleep 0.3
[ "$(posts)" = "$n" ] && ok "…and neither a plain pane nor an armed wait touches the row" || bad "the row was re-posted without cause"
scene menu-noauto 0; drive select "$SID" rate_limit "$LIMIT_LINE"
[ -z "$(keys)" ] && ok "a menu without the Wait-here row gets no keys" || bad "keys on a menu without the row: $(keys)"
if wait_posts $((n + 1)); then
  B="$(last_body)"
  printf '%s' "$B" | jq -e --arg m "$LIMIT_LINE" '.action == "open" and .kind == "blocked" and .auto_continue == false
       and .cause == "rate_limit" and .message == ($m + " · options menu on screen offers no automatic wait — not selected")' >/dev/null \
    && ok "…and the row is re-opened AT ONCE (second look) with auto_continue:false, the reason appended to the printed line" \
    || bad "re-open payload wrong: $B"
else
  bad "a menu the driver could not use did not re-open the row"
fi
n="$(posts)"
scene menu-usage 0; drive select "$SID" rate_limit "$LIMIT_LINE"
[ -z "$(keys)" ] && wait_posts $((n + 1)) && last_body | jq -e '.auto_continue == false and (.message | endswith("offers no automatic wait — not selected"))' >/dev/null \
  && ok "usage-based billing's menu (a bare 'Stop' row, no wait) is still the menu: no keys, the row re-opened as won't continue" \
  || bad "the usage-based menu was not recognised: keys '$(keys)', $(( $(posts) - n )) posts"
# A TUI that redraws 0.7 s late: every key must wait for its move, and Enter for a steady frame.
quiesce; scene menu 0; echo 700 > "$TMUX_STUB/lag_ms"
drive select "$SID" rate_limit "$LIMIT_LINE"
sleep 0.8; env -i PATH="$PATH_S" TMUX_STUB="$TMUX_STUB" tmux has-session -t "=sbjob-$SID"   # let the last key land
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Down,Enter" ] && [ "$(cat "$TMUX_STUB/picked" 2>/dev/null)" = "Wait here, then continue automatically at 4pm" ] \
  && ok "a TUI that redraws late gets one key per step and Enter only on a steady frame — no overshoot" \
  || bad "a slow redraw made the driver overshoot: keys $(keys | paste -sd'|' -), picked '$(cat "$TMUX_STUB/picked" 2>/dev/null)'"
# The menu changes under the pointer (a promo row loads in) while the frame on screen is still the old one:
# only a second, steady look keeps Enter off the row that slid under the pointer.
quiesce; scene menu-promo 1; echo 400 > "$TMUX_STUB/render_lag"; date +%s%3N > "$TMUX_STUB/shift_at"
drive select "$SID" rate_limit "$LIMIT_LINE"
[ "$(cat "$TMUX_STUB/picked" 2>/dev/null)" = "Wait here, then continue automatically at 4pm" ] \
  && ok "a menu that changes under the pointer (an async promo row) never gets Enter on a stale frame — two agreeing looks first" \
  || bad "Enter landed on '$(cat "$TMUX_STUB/picked" 2>/dev/null)' after the menu shifted (keys $(keys | paste -sd'|' -))"
n="$(posts)"
scene menu-nofocus 0; drive select "$SID" rate_limit "$LIMIT_LINE"
[ -z "$(keys)" ] && ok "a menu with no pointer line found gets no keys (a key is never guessed)" || bad "keys without a pointer: $(keys)"
wait_posts $((n + 1)) && last_body | jq -e --arg m "$LIMIT_LINE" \
    '.auto_continue == false and .message == ($m + " · options menu on screen — not selected")' >/dev/null \
  && ok "…and it too ends as auto_continue:false once the budget is spent ('options menu on screen — not selected')" \
  || bad "no re-open after an unusable menu: $(last_body 2>/dev/null)"
# Seen once, then gone before the driver could act (answered on the desktop): the LAST look decides, so
# the row is not turned into "won't continue" for a wait somebody else armed.
n="$(posts)"; scene menu-nofocus 0; echo "1 plain" > "$TMUX_STUB/scene-next"
drive select "$SID" rate_limit "$LIMIT_LINE"; sleep 0.3
[ -z "$(keys)" ] && [ "$(posts)" = "$n" ] && tail -1 "$LOG" | grep -q 'closed without the driver' \
  && ok "a menu that closes on its own before the budget ends: no keys, no re-open (judged on the last look)" \
  || bad "a menu answered elsewhere was still reported: keys '$(keys)', $(( $(posts) - n )) posts, log: $(tail -1 "$LOG")"
scene menu 0; sed -i '1d' "$TMUX_STUB/sessions"; drive select "$SID" rate_limit "$LIMIT_LINE"
[ -z "$(keys)" ] && ok "no tmux session sbjob-<session_id> (cancelled, moved, a Mac box): no keys" || bad "keys without a session: $(keys)"
echo "sbjob-$SID" > "$TMUX_STUB/sessions"
# One driver per session: a second one started while the first runs exits at once, silently. Without
# the lock both would act, and the one that lost the race would then re-open the row as "not selected"
# after its budget — a false "won't continue" on a wait the other one armed.
quiesce; scene menu 0; n="$(posts)"; lines0="$(menu_lines)"
env -i PATH="$PATH_S" HOME="$HOME" TMUX_STUB="$TMUX_STUB" bash "$HOME/.local/bin/sb-usage-limit-menu.sh" select "$SID" rate_limit "$LIMIT_LINE" & p1=$!
sleep 0.1
env -i PATH="$PATH_S" HOME="$HOME" TMUX_STUB="$TMUX_STUB" bash "$HOME/.local/bin/sb-usage-limit-menu.sh" select "$SID" rate_limit "$LIMIT_LINE" & p2=$!
wait "$p1" "$p2"; sleep 0.3
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Down,Enter" ] && [ "$(menu_lines)" = $((lines0 + 1)) ] && [ "$(posts)" = "$n" ] \
  && ok "two drivers for one session: one acts, the other leaves at once (flock) — one closing line, no re-open" \
  || bad "two drivers both acted: keys $(keys | paste -sd'|' -), $(( $(menu_lines) - lines0 )) closing lines, $(( $(posts) - n )) posts"
# The lock file outlives its driver on purpose (removing it lets two drivers lock two inodes at once);
# the SessionStart janitor prunes week-old ones.
LOCKF="$HOME/.sidebutton/usage-limit-menu-$SID.lock"
[ -e "$LOCKF" ] && ok "the driver leaves its lock file in place when it exits" || bad "the driver removed its lock file"
awk "/cat > .*sb-session-start.sh.*<<'SESSIONEOF'/{f=1;next} /^SESSIONEOF\$/{f=0} f" "$HOOK" > "$TMP/sb-session-start.sh"
OLDLOCK="$HOME/.sidebutton/usage-limit-menu-11111111-2222-4333-8444-555555555555.lock"
: > "$OLDLOCK"; touch -d '8 days ago' "$OLDLOCK"
printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"source\":\"startup\"}" \
  | env -i PATH="$PATH_S" HOME="$HOME" bash "$TMP/sb-session-start.sh" >/dev/null 2>&1
[ ! -e "$OLDLOCK" ] && [ -e "$LOCKF" ] && ok "sb-session-start.sh's janitor prunes a week-old driver lock and keeps a fresh one" \
  || bad "the janitor left a week-old lock or removed a fresh one"

# ── 4. the quota notifications and the Stop ────────────────────────────────────────────────────────
n="$(posts)"
fire "$(notif quota_auto_resume_fired "Usage limit reset · continuing automatically")" >/dev/null
wait_posts $((n + 1)) && [ "$(last_body)" = "$(jq -nc --arg sid "$SID" '{action:"resolve", session_id:$sid, kind:"blocked"}')" ] \
  && ok "quota_auto_resume_fired -> {action:resolve, session_id, kind:blocked} (the keyed resolve of that one row)" \
  || bad "quota_auto_resume_fired did not resolve the row: $(last_body 2>/dev/null)"
n="$(posts)"
fire "$(jq -nc --arg sid "$SID" '{hook_event_name:"Stop", session_id:$sid, stop_hook_active:false}')" >/dev/null
wait_posts $((n + 1)) && [ "$(last_body)" = "$(jq -nc --arg sid "$SID" '{action:"resolve", session_id:$sid}')" ] \
  && ok "a later Stop -> the existing bulk resolve, which closes the blocked row too" || bad "Stop did not bulk-resolve"
n="$(posts)"
DISABLED="Automatic continue was turned off · this task will not resume on its own"
fire "$(notif quota_auto_resume_disabled "$DISABLED")" >/dev/null
wait_posts $((n + 1)) && [ "$(last_body)" = "$(jq -nc --arg sid "$SID" --arg m "$DISABLED" \
    '{action:"open", session_id:$sid, kind:"blocked", cause:"rate_limit", message:$m, auto_continue:false}')" ] \
  && ok "quota_auto_resume_disabled -> the row re-opened with auto_continue:false" || bad "_disabled payload: $(last_body 2>/dev/null)"
n="$(posts)"; scene stale 0; lines0="$(menu_lines)"
fire "$(notif quota_auto_resume_stale "Usage limit has reset · press enter to continue")" >/dev/null
wait_menu_line "$lines0"
[ "$(keys | awk '{print $2}' | paste -sd, -)" = "Enter" ] && ok "quota_auto_resume_stale on a 'press enter to continue' pane -> exactly one Enter" \
  || bad "_stale keys: $(keys | paste -sd'|' -)"
sleep 0.3; [ "$(posts)" = "$n" ] && ok "…and no row change" || bad "_stale posted something"
scene plain 0; lines0="$(menu_lines)"
fire "$(notif quota_auto_resume_stale "Usage limit has reset · press enter to continue")" >/dev/null
wait_menu_line "$lines0"
[ -z "$(keys)" ] && ok "quota_auto_resume_stale on a pane without that prompt -> no keys" || bad "Enter sent to a pane without the prompt: $(keys)"
scene stale-old 0; lines0="$(menu_lines)"
fire "$(notif quota_auto_resume_stale "Usage limit has reset · press enter to continue")" >/dev/null
wait_menu_line "$lines0"
[ -z "$(keys)" ] && ok "…nor when the words are only old transcript text above the live bottom of the screen" \
  || bad "Enter sent because of old transcript text: $(keys)"
n="$(posts)"
fire "$(notif idle_prompt "Claude is waiting for your input")" >/dev/null; sleep 0.5
[ "$(posts)" = "$n" ] && ok "idle_prompt is still dropped (KAN-205's fall-through untouched)" || bad "idle_prompt posted"

# ── 5. a non-job session posts nothing and drives nothing ──────────────────────────────────────────
n="$(posts)"; scene menu 0; lines0="$(menu_lines)"
OTHER="$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')" | jq -c '.session_id = "99999999-0000-4000-8000-000000000000"')"
fire "$OTHER" >/dev/null
fire "$(notif quota_auto_resume_fired "x" | jq -c '.session_id = "99999999-0000-4000-8000-000000000000"')" >/dev/null
sleep 1.5
[ "$(posts)" = "$n" ] && [ -z "$(keys)" ] && [ "$(menu_lines)" = "$lines0" ] \
  && ok "a StopFailure / quota notification from another session (not the job's) posts nothing and starts no driver" \
  || bad "a non-job session was reported or driven"

# ── 5a. no job session known at all (between dispatches, an operator box, an old runtime's context) ─────
JCF="$HOME/.sidebutton/job-context.json"; mv "$JCF" "$JCF.saved"
n="$(posts)"; scene menu 0; lines0="$(menu_lines)"
fire "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')")" >/dev/null
fire "$(notif quota_auto_resume_disabled "Automatic continue was turned off")" >/dev/null
fire "$(notif quota_auto_resume_fired "x")" >/dev/null
fire "$(notif quota_auto_resume_stale "press enter to continue")" >/dev/null
printf '{"job_id":77,"step_index":0}\n' > "$JCF"     # a context that names no session
fire "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')")" >/dev/null
sleep 1.5
[ "$(posts)" = "$n" ] && [ -z "$(keys)" ] && [ "$(menu_lines)" = "$lines0" ] \
  && ok "with no job session known (no job context, or one naming no session) StopFailure and the quota notifications post nothing and start no driver" \
  || bad "a session with no job context was reported or driven: $(tail -1 "$PLOG" 2>/dev/null)"
mv "$JCF.saved" "$JCF"; quiesce

# ── 5b. a StopFailure checkpoints the job session's transcript at once ────────────────────────────────
TRJ="$HOME/.claude/projects/-home-agent-workspace/$SID.jsonl"; mkdir -p "$(dirname "$TRJ")"
printf '{"type":"user","message":{"content":"go"}}\n{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"%s"}]}}\n' "$LIMIT_LINE" > "$TRJ"
date +%s > "$HOME/.sidebutton/last-checkpoint"   # a fresh window: a PostToolUse checkpoint would be throttled
n="$(posts)"; scene plain 0
fire "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')" "$(jq -nc --arg tp "$TRJ" '{transcript_path:$tp}')")" >/dev/null
for _ in $(seq 1 40); do grep -q '"/api/jobs/transcript"' "$PLOG" && break; sleep 0.1; done
CK="$(grep '"/api/jobs/transcript"' "$PLOG" | tail -1)"
[ -n "$CK" ] && [ "$(printf '%s' "$CK" | jq -r .query.checkpoint)" = 1 ] && [ "$(printf '%s' "$CK" | jq -r .query.session_id)" = "$SID" ] \
  && [ "$(printf '%s' "$CK" | jq -r .body)" = "$(cat "$TRJ")" ] \
  && ok "a StopFailure on the job session uploads a checkpoint at once (throttle bypassed): the portal's copy ends where the session blocked" \
  || bad "no checkpoint followed the StopFailure"
quiesce

# ── 5c. the per-box switch reads the same for the StopFailure checkpoint as for the PostToolUse one ─────
cp "$HOME/.agent-env" "$HOME/.agent-env.saved"
for off in 00 000; do
  cp "$HOME/.agent-env.saved" "$HOME/.agent-env"; echo "SB_CHECKPOINT_INTERVAL_SEC=$off" >> "$HOME/.agent-env"
  ck_before="$(grep -c '"/api/jobs/transcript"' "$PLOG")"; scene plain 0
  fire "$(stopfailure rate_limit "$(jq -n --arg m "$LIMIT_LINE" '$m')" "$(jq -nc --arg tp "$TRJ" '{transcript_path:$tp}')")" >/dev/null
  sleep 1.5
  [ "$(grep -c '"/api/jobs/transcript"' "$PLOG")" = "$ck_before" ] \
    && ok "SB_CHECKPOINT_INTERVAL_SEC=$off switches the StopFailure checkpoint off, as it does the PostToolUse one" \
    || bad "SB_CHECKPOINT_INTERVAL_SEC=$off still uploaded a checkpoint on StopFailure"
  quiesce
done
mv "$HOME/.agent-env.saved" "$HOME/.agent-env"

# ── 6. the whole run, every key: only Down, Up and Enter ────────────────────────────────────────────
if [ -s "$TMUX_STUB/all-keys.log" ] \
   && awk 'NF != 2 || ($2 != "Down" && $2 != "Up" && $2 != "Enter") {bad = 1} END {exit bad}' "$TMUX_STUB/all-keys.log"; then
  ok "across the whole run only Down, Up and Enter were sent ($(wc -l < "$TMUX_STUB/all-keys.log" | tr -d ' ') keys; never Esc, which cancels the wait, never text)"
else
  bad "another key was sent: $(sort "$TMUX_STUB/all-keys.log" 2>/dev/null | uniq -c | tr '\n' ' ')"
fi

finish
