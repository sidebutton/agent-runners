# 16c-agent-browser.sh — the agent browser: chrome.service (its start page) and the idle reset.
#
# WHY (fleet RCA 2026-10-05). Chrome runs on Xvfb with no GPU, so every frame of an animated page is
# composited in software, and a window on Xvfb counts as visible, so nothing throttles it. The start page
# was https://sidebutton.com, whose home page runs ~20 infinite CSS animations: idle agents sat at 55–74 %
# CPU of a 2-vCPU VM around the clock (CloudWatch hourly MIN ≈ 54 % = one vCPU pinned by Chrome's
# `--type=gpu-process`), and every job shared the box with it. The same page pointed at about:blank: ~1 %.
# Pages a job leaves open (the portal's live fleet page, any animated site) do the same until the next job
# navigates away — nothing resets the browser between jobs.
#
# This step does two things:
#   1. It OWNS chrome.service (moved here from 16-services-prep.sh, which is provision-only, so the
#      refresh path can reach the unit). The start page is AGENT_BROWSER_HOME (default https://kadmo.ai);
#      every flag is unchanged. The unit is rewritten only when its text differs, then daemon-reload. This
#      step NEVER starts or restarts Chrome: a changed unit takes effect at the next restart — the idle
#      reset below, a reboot, or an operator.
#   2. It installs /opt/sb-browser-idle.sh + sb-browser-idle.timer (every 5 min, root). When the agent has
#      been idle for SB_BROWSER_IDLE_SEC (default 15 min) — no job context, no running workflow, nobody on
#      the desktop (x11vnc :5910, xrdp :3389), Claude not working — and Chrome still burns CPU
#      (≥ SB_BROWSER_BUSY_PCT, default 20 % of one CPU over a 10 s sample), it restarts chrome.service (at
#      most once per SB_BROWSER_RESTART_EVERY_SEC, default 1 h): every tab closes, renderer memory is freed,
#      Chrome comes back on its start page. If the start page itself keeps Chrome busy, or a restart was
#      already spent this hour, it PARKS the browser instead: a blank tab in front, so the animated tab is
#      hidden and stops rendering. SB_BROWSER_IDLE_SEC=0 in ~/.agent-env turns the reset off.
#
# GATE — provision vs refresh. At provision components.sh exports INSTALL_CHROME (0/1) and this step mirrors
# what 16 did. The refresh path (base/lib-refresh.sh) re-runs manifest steps WITHOUT component flags (the trap
# 19f's header documents), so there the FILESYSTEM is the signal: a live box (the install marker exists)
# keeps a chrome.service only if it already has one. The idle reset needs the SideButton server (job context,
# workflows) and is a box Claude drives; a serverless box (SKIP_SIDEBUTTON_SERVER=1) is a person's desktop,
# so it gets the unit and never the reset.
#
# Sourced-safe: never exits the installer — logs WARN and continues.

step "Step 16c/16: agent browser (chrome.service start page + idle reset)"

AGENT_BROWSER_HOME="${AGENT_BROWSER_HOME:-https://kadmo.ai}"
SB_SYSTEMD_DIR="${SB_SYSTEMD_DIR:-/etc/systemd/system}"
SB_OPT_DIR="${SB_OPT_DIR:-/opt}"
CHROME_UNIT_FILE="${SB_SYSTEMD_DIR}/chrome.service"
BROWSER_IDLE_DEST="${SB_OPT_DIR}/sb-browser-idle.sh"

_want_chrome=0
if [ -n "${INSTALL_CHROME:-}" ]; then
  [ "$INSTALL_CHROME" = "1" ] && _want_chrome=1
elif [ -f "${INSTALL_MARKER:-/etc/sidebutton/installed}" ]; then
  [ -f "$CHROME_UNIT_FILE" ] && _want_chrome=1          # live box: keep what it was provisioned with
else
  _want_chrome=1                                        # provision with no gate: 16's old default
fi

_reload=0
if [ "$_want_chrome" != "1" ]; then
  if [ -f "$CHROME_UNIT_FILE" ] && [ "${INSTALL_CHROME:-}" = "0" ]; then
    rm -f "$CHROME_UNIT_FILE"
    _reload=1
  fi
  log "chrome.service not written (chrome component not selected)"
else
  # Ordering depends on whether sidebutton.service exists: when the SB server is absent
  # (SKIP_SIDEBUTTON_SERVER=1) drop it from After= so Chrome doesn't wait on a unit that never starts.
  if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
    _chrome_after='After=xfce-session.service'
  else
    _chrome_after='After=xfce-session.service sidebutton.service'
  fi
  _unit_tmp="$(mktemp)"
  cat > "$_unit_tmp" <<EOF
[Unit]
Description=Chrome Browser with SideButton Extension
${_chrome_after}
Requires=xvfb.service

[Service]
Type=simple
User=agent
Environment=DISPLAY=:10
ExecStartPre=/bin/bash -c 'rm -f /home/agent/.config/google-chrome/Singleton*'
ExecStart=/opt/google/chrome/chrome \\
  --no-first-run \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --noerrdialogs \\
  --disable-features=InfiniteSessionRestore \\
  --profile-directory=Default \\
  ${AGENT_BROWSER_HOME}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  if [ -f "$CHROME_UNIT_FILE" ] && cmp -s "$_unit_tmp" "$CHROME_UNIT_FILE"; then
    log "chrome.service unchanged (start page ${AGENT_BROWSER_HOME})"
  else
    mkdir -p "$SB_SYSTEMD_DIR"
    install -m 0644 "$_unit_tmp" "$CHROME_UNIT_FILE"
    _reload=1
    log "chrome.service written (start page ${AGENT_BROWSER_HOME}) — takes effect at Chrome's next restart"
  fi
  rm -f "$_unit_tmp"
fi

if [ "$_want_chrome" = "1" ] && [ "${SKIP_SIDEBUTTON_SERVER:-}" != "1" ]; then
  mkdir -p "$SB_OPT_DIR"
  cat > "$BROWSER_IDLE_DEST" <<'EOF'
#!/usr/bin/env bash
# /opt/sb-browser-idle.sh — give the CPU back when the agent browser animates a page nobody is using.
# Installed by agent-runners base/16c (see its header for the why). Runs as root from sb-browser-idle.timer.
#
# One decision per tick:
#   not idle (a job, a workflow, a person at the desktop, Claude working) -> forget the idle clock, do nothing
#   idle for less than SB_BROWSER_IDLE_SEC                                -> start/keep the idle clock
#   idle long enough, Chrome quiet (< SB_BROWSER_BUSY_PCT)                -> nothing to do
#   idle long enough, Chrome busy, no restart this hour                   -> restart chrome.service (start page)
#     ...and Chrome still busy on its own start page                      -> park (blank tab in front)
#   idle long enough, Chrome busy, a restart already spent this hour      -> park
# Everything it decides goes to the journal: journalctl -t sb-browser-idle
set -uo pipefail

AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/${AGENT_USER}}"
IDLE_SEC="${SB_BROWSER_IDLE_SEC:-900}"
BUSY_PCT="${SB_BROWSER_BUSY_PCT:-20}"
SAMPLE_SEC="${SB_BROWSER_SAMPLE_SEC:-10}"
RESTART_EVERY_SEC="${SB_BROWSER_RESTART_EVERY_SEC:-3600}"
SETTLE_SEC="${SB_BROWSER_SETTLE_SEC:-45}"
STATE_DIR="${SB_BROWSER_IDLE_STATE_DIR:-/var/lib/sb-browser-idle}"
JOB_CONTEXT="${SB_JOB_CONTEXT:-${AGENT_HOME}/.sidebutton/job-context.json}"
SB_URL="${SB_URL:-http://127.0.0.1:9876}"
UNIT="${SB_CHROME_UNIT:-chrome.service}"
DESKTOP_PORTS="${SB_DESKTOP_PORTS:-5910 3389}"
DISPLAY_NUM="${SB_AGENT_DISPLAY:-:10}"

say() { logger -t sb-browser-idle -- "$*" 2>/dev/null || true; printf '%s\n' "$*"; }

case "$IDLE_SEC" in ''|*[!0-9]*) IDLE_SEC=900 ;; esac
[ "$IDLE_SEC" -eq 0 ] && exit 0                         # turned off in ~/.agent-env

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
NOW="${SB_NOW:-$(date +%s)}"                          # SB_NOW / SB_BROWSER_CPU_PCT: for the tests

# Why the agent is NOT idle, or nothing when it is.
busy_reason() {
  [ -f "$JOB_CONTEXT" ] && { echo "a job is running"; return; }
  if [ -n "${SIDEBUTTON_AGENT_TOKEN:-}" ]; then
    local n
    n=$(curl -s --max-time 3 -H "Authorization: Bearer ${SIDEBUTTON_AGENT_TOKEN}" "${SB_URL}/api/running-workflows" 2>/dev/null \
      | jq -r '(.workflows // []) | length' 2>/dev/null || true)
    case "$n" in ''|0|*[!0-9]*) ;; *) echo "${n} workflow(s) running"; return ;; esac
  fi
  local p
  for p in $DESKTOP_PORTS; do
    if ss -Htn state established "( sport = :${p} )" 2>/dev/null | grep -q .; then
      echo "someone is on the desktop (:${p})"; return
    fi
  done
  local c
  c=$(curl -s --max-time 3 "${SB_URL}/health" 2>/dev/null | jq -r '.system_metrics.claude_code_cpu // 0' 2>/dev/null || true)
  case "$c" in ''|*[!0-9.]*) c=0 ;; esac
  if awk -v c="$c" 'BEGIN { exit !(c + 0 >= 5) }'; then echo "Claude is working (${c}% CPU)"; return; fi
}

# "pid ticks" for every Chrome process of the agent user (utime + stime, from /proc/<pid>/stat).
chrome_ticks() {
  local uid d comm rest
  uid=$(id -u "$AGENT_USER" 2>/dev/null) || return 0
  for d in /proc/[0-9]*; do
    [ "$(stat -c %u "$d" 2>/dev/null)" = "$uid" ] || continue
    comm=$(cat "$d/comm" 2>/dev/null) || continue
    case "$comm" in chrome|chromium|chromium-browse*) ;; *) continue ;; esac
    rest=$(sed 's/^.*) //' "$d/stat" 2>/dev/null) || continue
    # shellcheck disable=SC2086
    set -- $rest                                        # $1 = state (field 3) … $12 = utime, $13 = stime
    [ $# -ge 13 ] && echo "${d#/proc/} $(( ${12} + ${13} ))"
  done
}

# Chrome's CPU, in % of one CPU, over SAMPLE_SEC — every Chrome process of the agent user together.
chrome_cpu_pct() {
  if [ -n "${SB_BROWSER_CPU_PCT:-}" ]; then echo "$SB_BROWSER_CPU_PCT"; return; fi   # tests
  local a b hz
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  a=$(chrome_ticks); sleep "$SAMPLE_SEC"; b=$(chrome_ticks)
  awk -v hz="$hz" -v s="$SAMPLE_SEC" 'NR == FNR { t[$1] = $2; next } ($1 in t) { d += $2 - t[$1] }
    END { printf "%d\n", (d / hz / s) * 100 }' <(printf '%s\n' "$a") <(printf '%s\n' "$b")
}

browser_connected() {
  curl -s --max-time 3 "${SB_URL}/health" 2>/dev/null | jq -e '.browser_connected == true' >/dev/null 2>&1
}

wait_connected() {                                      # $1 = seconds
  local t=0
  while [ "$t" -lt "$1" ]; do
    browser_connected && return 0
    sleep 5; t=$((t + 5))
  done
  return 1
}

chrome_bin() {
  [ -n "${SB_CHROME_BIN:-}" ] && { echo "$SB_CHROME_BIN"; return; }   # tests
  local b
  for b in /opt/google/chrome/chrome /usr/bin/chromium-browser /usr/bin/chromium; do
    [ -x "$b" ] && { echo "$b"; return; }
  done
}

# A blank tab in front: the animated tab goes to the background, where Chrome stops rendering it. The
# command hands the URL to the running browser (its process singleton) and returns; it runs in the
# foreground because systemd ends a oneshot's leftover children with it, and a timeout bounds it.
park() {
  local bin; bin=$(chrome_bin)
  [ -n "$bin" ] || { say "no Chrome binary found — cannot park"; return 0; }
  timeout 20 runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" DISPLAY="$DISPLAY_NUM" "$bin" about:blank >/dev/null 2>&1 || true
  say "parked: blank tab in front ($1)"
}

reason=$(busy_reason)
if [ -n "$reason" ]; then
  rm -f "$STATE_DIR/idle-since"
  exit 0
fi
[ -f "$STATE_DIR/idle-since" ] || echo "$NOW" > "$STATE_DIR/idle-since"
since=$(cat "$STATE_DIR/idle-since" 2>/dev/null || echo "$NOW")
case "$since" in ''|*[!0-9]*) since=$NOW ;; esac
idle=$((NOW - since))
[ "$idle" -ge "$IDLE_SEC" ] || exit 0

systemctl is-active --quiet "$UNIT" 2>/dev/null || exit 0
pct=$(chrome_cpu_pct)
case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
[ "$pct" -ge "$BUSY_PCT" ] || exit 0

# A job may have been dispatched while we sampled: look once more right before acting.
reason=$(busy_reason)
if [ -n "$reason" ]; then
  rm -f "$STATE_DIR/idle-since"
  exit 0
fi

last=$(cat "$STATE_DIR/last-restart" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $((NOW - last)) -lt "$RESTART_EVERY_SEC" ]; then
  park "idle $((idle / 60)) min, Chrome at ${pct}% CPU, restarted $(( (NOW - last) / 60 )) min ago"
  exit 0
fi

echo "$NOW" > "$STATE_DIR/last-restart"
say "idle $((idle / 60)) min, Chrome at ${pct}% CPU — restarting ${UNIT}"
if ! systemctl restart "$UNIT" 2>/dev/null; then
  say "WARN: systemctl restart ${UNIT} failed"
  exit 0
fi
if ! wait_connected 60; then                            # the extension's reconnect, as in SCRUM-1172
  say "browser not connected 60 s after the restart — restarting once more"
  systemctl restart "$UNIT" 2>/dev/null || true
  wait_connected 60 || say "WARN: browser still not connected"
fi
sleep "$SETTLE_SEC"
pct=$(chrome_cpu_pct)
case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
if [ "$pct" -ge "$BUSY_PCT" ]; then
  park "its start page keeps Chrome at ${pct}% CPU"
else
  say "Chrome quiet after the restart (${pct}% CPU)"
fi
exit 0
EOF
  chmod 0755 "$BROWSER_IDLE_DEST"

  # Root: the reset restarts chrome.service and reads every Chrome process of the agent user. The agent env
  # brings SIDEBUTTON_AGENT_TOKEN (the running-workflows check) and the SB_BROWSER_* overrides; it is
  # optional (leading '-') so a not-yet-populated env never blocks the timer.
  cat > "${SB_SYSTEMD_DIR}/sb-browser-idle.service" <<'EOF'
[Unit]
Description=Reset the agent browser when it burns CPU on a page nobody is using
After=chrome.service

[Service]
Type=oneshot
EnvironmentFile=-/home/agent/.agent-env
ExecStart=/opt/sb-browser-idle.sh
EOF
  cat > "${SB_SYSTEMD_DIR}/sb-browser-idle.timer" <<'EOF'
[Unit]
Description=Check the agent browser at boot+10min and every 5 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  _reload=1
  log "browser idle reset installed: ${BROWSER_IDLE_DEST} (sb-browser-idle.timer, every 5 min)"
else
  # No Chrome, or a serverless box (a person's desktop): no reset — and none left over from before.
  if [ -f "${SB_SYSTEMD_DIR}/sb-browser-idle.timer" ]; then
    systemctl disable --now sb-browser-idle.timer >/dev/null 2>&1 || true
    rm -f "${SB_SYSTEMD_DIR}/sb-browser-idle.timer" "${SB_SYSTEMD_DIR}/sb-browser-idle.service" "$BROWSER_IDLE_DEST"
    _reload=1
    log "browser idle reset removed (no Chrome, or no SideButton server)"
  fi
fi

if [ "$_reload" = "1" ]; then
  systemctl daemon-reload >/dev/null 2>&1 || log "WARN: systemctl daemon-reload failed"
fi
if [ -f "${SB_SYSTEMD_DIR}/sb-browser-idle.timer" ]; then
  systemctl enable --now sb-browser-idle.timer >/dev/null 2>&1 \
    || log "WARN: failed to enable sb-browser-idle.timer"
fi
