#!/usr/bin/env bash
# base/tests/test-16c-agent-browser.sh — regression guard for the agent browser step (fleet RCA 2026-10-05).
#
# Chrome on Xvfb has no GPU: an animated page keeps its GPU process at ~95 % of a vCPU, and the old start page
# (https://sidebutton.com, ~20 infinite CSS animations) held idle agents at 55–74 % CPU of a 2-vCPU VM. Base/16c
# owns chrome.service (start page AGENT_BROWSER_HOME, default https://kadmo.ai) and installs sb-browser-idle,
# which restarts or parks a browser that burns CPU while the agent is idle.
#
# What this proves:
#   1. The gate works the same at provision (INSTALL_CHROME 0/1) and on a refresh (no component flags: a live box
#      keeps a chrome.service only if it has one), and a serverless box never gets the reset.
#   2. The unit keeps every flag 16 had, carries the start page, is rewritten only when it differs, and the step
#      never restarts Chrome.
#   3. The reset's decision table: nothing while a job, a workflow, a person at the desktop or Claude is busy;
#      nothing before 15 idle minutes or while Chrome is quiet; one restart per hour, then park; park when the
#      start page itself keeps Chrome busy; a second restart when the extension does not reconnect.
#   4. The wiring: run.sh sources 16c right after 16, 16 no longer writes the unit, the refresh manifest lists
#      16b and 16c, and the wallpaper image is in the refresh fingerprint.
#
# Pure bash + jq. Run: bash base/tests/test-16c-agent-browser.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
STEP="$BASE/16c-agent-browser.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── stubs ──────────────────────────────────────────────────────────────────────
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${STUB_LOG:?}"
case "$1" in
  is-active) exit "${STUB_ACTIVE:-0}" ;;
  restart)   echo restart >> "${STUB_RESTARTS:?}"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  */health) printf '{"browser_connected":%s,"system_metrics":{"claude_code_cpu":%s}}' "${STUB_CONNECTED:-true}" "${STUB_CLAUDE_CPU:-0}" ;;
  */api/running-workflows) printf '{"workflows":%s}' "${STUB_WORKFLOWS:-[]}" ;;
esac
EOF
cat > "$STUB/ss" <<'EOF'
#!/usr/bin/env bash
case "$*" in *":${STUB_SS_PORT:-none} "*) echo "ESTAB 0 0 10.0.0.5:${STUB_SS_PORT} 1.2.3.4:5555" ;; esac
EOF
cat > "$STUB/runuser" <<'EOF'
#!/usr/bin/env bash
echo "runuser $*" >> "${STUB_LOG:?}"
EOF
cat > "$STUB/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/logger"
chmod +x "$STUB"/*

# Run the step in a sandbox. Extra env assignments come as arguments.
run_step() {
  local root="$1"; shift
  mkdir -p "$root/systemd" "$root/opt"
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP" STUB_LOG="$root/systemctl.log" STUB_RESTARTS="$root/restarts" \
    LOG_FILE="$root/install.log" SB_SYSTEMD_DIR="$root/systemd" SB_OPT_DIR="$root/opt" \
    INSTALL_MARKER="$root/installed" BASE_DIR="$BASE" "$@" \
    bash -c 'set -euo pipefail; . "$BASE_DIR/lib.sh"; . "$BASE_DIR/16c-agent-browser.sh"' >/dev/null 2>&1
}

# ── 0. syntax ──────────────────────────────────────────────────────────────────
bash -n "$STEP" 2>/dev/null && ok "bash -n: 16c-agent-browser.sh" || bad "16c missing / syntax error"
awk "/cat > \"\\\$BROWSER_IDLE_DEST\" <<'EOF'/{f=1;next} /^EOF\$/{f=0} f" "$STEP" > "$TMP/sb-browser-idle.sh"
chmod +x "$TMP/sb-browser-idle.sh"
[ -s "$TMP/sb-browser-idle.sh" ] && bash -n "$TMP/sb-browser-idle.sh" \
  && ok "bash -n: generated sb-browser-idle.sh" || bad "generated sb-browser-idle.sh missing / syntax error"

# ── 1. provision, chrome + server: unit with the start page, the reset installed ──
R="$TMP/p1"; run_step "$R" INSTALL_CHROME=1 SKIP_SIDEBUTTON_SERVER=0
U="$R/systemd/chrome.service"
if [ -f "$U" ]; then
  grep -q '^  https://kadmo.ai$' "$U" && ok "start page is https://kadmo.ai" || bad "start page is not https://kadmo.ai"
  ! grep -q 'sidebutton.com' "$U" && ok "no sidebutton.com in the unit" || bad "the unit still opens sidebutton.com"
  flags_ok=1
  for f in --no-first-run --disable-session-crashed-bubble --disable-infobars --noerrdialogs \
           --disable-features=InfiniteSessionRestore --profile-directory=Default; do
    grep -q -- "  ${f} \\\\$" "$U" || flags_ok=0
  done
  [ "$flags_ok" = 1 ] && ok "every flag 16 had is kept" || bad "a Chrome flag changed"
  grep -q '^After=xfce-session.service sidebutton.service$' "$U" && ok "ordered after sidebutton.service" || bad "After= wrong with the server on"
  grep -q '^Environment=DISPLAY=:10$' "$U" && grep -q '^User=agent$' "$U" && ok "runs as agent on :10" || bad "user/display changed"
else
  bad "chrome.service not written at provision with INSTALL_CHROME=1"
fi
[ -x "$R/opt/sb-browser-idle.sh" ] && [ -f "$R/systemd/sb-browser-idle.timer" ] && [ -f "$R/systemd/sb-browser-idle.service" ] \
  && ok "idle reset installed (script, service, timer)" || bad "idle reset not installed"
grep -q '^OnUnitActiveSec=5min$' "$R/systemd/sb-browser-idle.timer" 2>/dev/null && ok "timer every 5 min" || bad "timer cadence wrong"
grep -q 'enable --now sb-browser-idle.timer' "$R/systemctl.log" && ok "timer enabled" || bad "timer not enabled"
grep -q 'daemon-reload' "$R/systemctl.log" && ok "daemon-reload after writing units" || bad "no daemon-reload"
grep -Eq 'restart|start chrome' "$R/systemctl.log" && bad "the step started/restarted Chrome" || ok "the step never starts or restarts Chrome"

# ── 2. idempotent: a second run leaves the unit alone ────────────────────────────
before=$(stat -c %Y "$U" 2>/dev/null); /bin/sleep 1
run_step "$R" INSTALL_CHROME=1 SKIP_SIDEBUTTON_SERVER=0
after=$(stat -c %Y "$U" 2>/dev/null)
[ "$before" = "$after" ] && grep -q 'chrome.service unchanged' "$R/install.log" \
  && ok "unchanged unit is not rewritten" || bad "unit rewritten although unchanged"

# ── 3. the start page can be set ───────────────────────────────────────────────
R="$TMP/p3"; run_step "$R" INSTALL_CHROME=1 AGENT_BROWSER_HOME=about:blank
grep -q '^  about:blank$' "$R/systemd/chrome.service" 2>/dev/null && ok "AGENT_BROWSER_HOME sets the start page" || bad "AGENT_BROWSER_HOME ignored"

# ── 4. INSTALL_CHROME=0 removes the unit and the reset ─────────────────────────
R="$TMP/p4"; mkdir -p "$R/systemd"; echo old > "$R/systemd/chrome.service"; echo t > "$R/systemd/sb-browser-idle.timer"
run_step "$R" INSTALL_CHROME=0
[ ! -f "$R/systemd/chrome.service" ] && ok "INSTALL_CHROME=0 removes chrome.service" || bad "INSTALL_CHROME=0 left chrome.service"
[ ! -f "$R/systemd/sb-browser-idle.timer" ] && ok "INSTALL_CHROME=0 removes the reset" || bad "INSTALL_CHROME=0 left the reset"

# ── 5. refresh (no component flags) on a live box WITHOUT Chrome: nothing ───────
R="$TMP/p5"; mkdir -p "$R"; echo "runners_ref=main" > "$R/installed"
run_step "$R"
[ ! -f "$R/systemd/chrome.service" ] && [ ! -f "$R/systemd/sb-browser-idle.timer" ] \
  && ok "refresh on a box without chrome.service writes nothing" || bad "refresh created Chrome units on a box without Chrome"

# ── 6. refresh on a live box WITH the old unit: rewritten, reset added, Chrome untouched ──
R="$TMP/p6"; mkdir -p "$R/systemd"; echo "runners_ref=main" > "$R/installed"
printf '[Service]\nExecStart=/opt/google/chrome/chrome https://sidebutton.com\n' > "$R/systemd/chrome.service"
run_step "$R"
grep -q '^  https://kadmo.ai$' "$R/systemd/chrome.service" && ok "refresh rewrites the live unit with the new start page" || bad "refresh did not rewrite the live unit"
[ -f "$R/systemd/sb-browser-idle.timer" ] && ok "refresh installs the reset on a live box" || bad "refresh did not install the reset"
grep -q 'restart' "$R/systemctl.log" && bad "refresh restarted something" || ok "refresh restarts nothing (the unit applies at Chrome's next restart)"

# ── 7. serverless box: the unit, never the reset ───────────────────────────────
R="$TMP/p7"; mkdir -p "$R/systemd"; echo t > "$R/systemd/sb-browser-idle.timer"
run_step "$R" INSTALL_CHROME=1 SKIP_SIDEBUTTON_SERVER=1
grep -q '^After=xfce-session.service$' "$R/systemd/chrome.service" && ok "serverless: not ordered after sidebutton.service" || bad "serverless After= wrong"
[ ! -f "$R/systemd/sb-browser-idle.timer" ] && ok "serverless: no reset (and an old one removed)" || bad "serverless box kept a reset"

# ── 8. the reset's decision table ──────────────────────────────────────────────
NOW=2000000000
idle() {   # idle <case dir> [env…]  — runs the generated script with stubs
  local d="$1"; shift
  mkdir -p "$d/state" "$d/home/.sidebutton"
  : > "$d/log"; : > "$d/restarts"
  env -i PATH="$STUB:/usr/bin:/bin" STUB_LOG="$d/log" STUB_RESTARTS="$d/restarts" \
    AGENT_USER="$(id -un)" AGENT_HOME="$d/home" SB_BROWSER_IDLE_STATE_DIR="$d/state" \
    SB_JOB_CONTEXT="$d/home/.sidebutton/job-context.json" SB_NOW="$NOW" SB_BROWSER_SETTLE_SEC=0 \
    SB_CHROME_BIN=/opt/google/chrome/chrome "$@" \
    bash "$TMP/sb-browser-idle.sh" >/dev/null 2>&1
}
restarts() { wc -l < "$1/restarts" | tr -d ' '; }
parked()   { grep -q 'about:blank' "$1/log"; }

C="$TMP/c1"; mkdir -p "$C/home/.sidebutton"; echo '{"job_id":1}' > "$C/home/.sidebutton/job-context.json"
mkdir -p "$C/state"; echo $((NOW - 3600)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90
[ "$(restarts "$C")" = 0 ] && ! parked "$C" && [ ! -f "$C/state/idle-since" ] \
  && ok "a job is running: nothing, and the idle clock is cleared" || bad "acted during a job"

for spec in "STUB_SS_PORT=5910|someone on VNC" "STUB_SS_PORT=3389|someone on RDP" \
            "STUB_CLAUDE_CPU=30|Claude working" "SIDEBUTTON_AGENT_TOKEN=t STUB_WORKFLOWS=[1]|a workflow running"; do
  vars="${spec%%|*}"; what="${spec#*|}"
  C="$TMP/c-${what// /-}"; mkdir -p "$C/state"; echo $((NOW - 3600)) > "$C/state/idle-since"
  # shellcheck disable=SC2086
  idle "$C" SB_BROWSER_CPU_PCT=90 $vars
  [ "$(restarts "$C")" = 0 ] && ! parked "$C" && ok "${what}: nothing" || bad "${what}: acted anyway"
done

C="$TMP/c2"; idle "$C" SB_BROWSER_CPU_PCT=90
[ "$(cat "$C/state/idle-since" 2>/dev/null)" = "$NOW" ] && [ "$(restarts "$C")" = 0 ] \
  && ok "first idle tick starts the idle clock and does nothing else" || bad "first idle tick acted or did not start the clock"

C="$TMP/c3"; mkdir -p "$C/state"; echo $((NOW - 600)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90
[ "$(restarts "$C")" = 0 ] && ! parked "$C" && ok "idle 10 min: nothing yet" || bad "acted before 15 idle minutes"

C="$TMP/c4"; mkdir -p "$C/state"; echo $((NOW - 1200)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=5
[ "$(restarts "$C")" = 0 ] && ! parked "$C" && ok "idle and Chrome quiet: nothing" || bad "acted on a quiet browser"

C="$TMP/c5"; mkdir -p "$C/state"; echo $((NOW - 1200)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90
[ "$(restarts "$C")" = 1 ] && [ "$(cat "$C/state/last-restart" 2>/dev/null)" = "$NOW" ] \
  && ok "idle and busy: one restart, stamped" || bad "idle+busy did not restart exactly once"
parked "$C" && ok "start page still busy after the restart: parked" || bad "busy start page was not parked"
grep -q "runuser -u $(id -un) -- env HOME=$C/home DISPLAY=:10 .* about:blank" "$C/log" \
  && ok "park opens about:blank as the agent user on :10" || bad "park command wrong"

C="$TMP/c6"; mkdir -p "$C/state"; echo $((NOW - 1200)) > "$C/state/idle-since"; echo $((NOW - 600)) > "$C/state/last-restart"
idle "$C" SB_BROWSER_CPU_PCT=90
[ "$(restarts "$C")" = 0 ] && parked "$C" && ok "restart already spent this hour: park only" || bad "restarted twice in an hour"

C="$TMP/c7"; mkdir -p "$C/state"; echo $((NOW - 1200)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90 STUB_ACTIVE=3
[ "$(restarts "$C")" = 0 ] && ! parked "$C" && ok "chrome.service not active: nothing" || bad "acted on an inactive Chrome"

C="$TMP/c8"; mkdir -p "$C/state"; echo $((NOW - 1200)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90 STUB_CONNECTED=false
[ "$(restarts "$C")" = 2 ] && ok "extension not reconnected: one more restart" || bad "no second restart when the browser stays disconnected"

C="$TMP/c9"; mkdir -p "$C/state"; echo $((NOW - 99999)) > "$C/state/idle-since"
idle "$C" SB_BROWSER_CPU_PCT=90 SB_BROWSER_IDLE_SEC=0
[ "$(restarts "$C")" = 0 ] && ! parked "$C" && ok "SB_BROWSER_IDLE_SEC=0 turns the reset off" || bad "SB_BROWSER_IDLE_SEC=0 did not turn it off"

# ── 9. wiring ─────────────────────────────────────────────────────────────────
n16=$(grep -n '/16-services-prep.sh"' "$BASE/run.sh" | cut -d: -f1)
n16c=$(grep -n '/16c-agent-browser.sh"' "$BASE/run.sh" | cut -d: -f1)
n17=$(grep -n '/17-services-start.sh"' "$BASE/run.sh" | cut -d: -f1)
[ -n "$n16" ] && [ -n "$n16c" ] && [ -n "$n17" ] && [ "$n16c" -gt "$n16" ] && [ "$n16c" -lt "$n17" ] \
  && ok "run.sh sources 16c after 16 and before 17 starts the services" || bad "run.sh order wrong (16=$n16 16c=$n16c 17=$n17)"
grep -q 'cat > /etc/systemd/system/chrome.service' "$BASE/16-services-prep.sh" \
  && bad "16 still writes chrome.service (two writers)" || ok "16 no longer writes chrome.service"
MANIFEST_STEPS="$( . "$BASE/lib-refresh.sh"; sb_refresh_manifest_files "$BASE" )"
grep -qx '16c-agent-browser.sh' <<<"$MANIFEST_STEPS" && ok "refresh manifest lists 16c (reaches the live fleet)" || bad "16c not in refresh-manifest.txt"
grep -qx '16b-wallpaper.sh' <<<"$MANIFEST_STEPS" && ok "refresh manifest lists 16b (the wallpaper reaches the live fleet)" || bad "16b not in refresh-manifest.txt"
grep -qx '16-services-prep.sh' <<<"$MANIFEST_STEPS" && bad "16 is listed — it is provision-only" || ok "16 stays provision-only"
grep -q 'assets/wallpaper.png' "$BASE/lib-refresh.sh" && ok "the wallpaper image is in the refresh fingerprint" || bad "an image-only change would not reach the fleet"
fp1=$( . "$BASE/lib-refresh.sh"; sb_base_artifacts_fingerprint "$BASE" )
cp -r "$BASE" "$TMP/base-copy" && printf 'x' >> "$TMP/base-copy/assets/wallpaper.png"
fp2=$( . "$BASE/lib-refresh.sh"; sb_base_artifacts_fingerprint "$TMP/base-copy" )
[ -n "$fp1" ] && [ "$fp1" != "$fp2" ] && ok "a new wallpaper flips the fingerprint" || bad "the fingerprint ignores the wallpaper"

exit "$fail"
