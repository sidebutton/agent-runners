# 19c-health-report.sh — periodic health + desktop-screenshot reporter.
#
# Publishes a rich health snapshot (system metrics + a full-desktop screenshot +
# the recent Claude session log) to the portal's POST /api/agents/health-report
# so the agent's preview on /portal/agents populates AUTOMATICALLY — first right
# after provisioning, then on a periodic timer. Without this the portal only
# shows a screenshot after an operator clicks the per-agent "refresh data"
# button (the fleet-status poll fetches /health for metrics but never pulls a
# screenshot).
#
# Mechanism: a oneshot service runs /opt/report-health-snapshot.sh --full (which
# always includes a screenshot), gated by a readiness wait so the very first
# frame is a painted desktop rather than black. A timer fires it ~30s after
# every boot and then every 5 minutes. An explicit start at install time gives
# the immediate first push (we are already past boot, so the timer's OnBootSec
# would not fire until the next reboot).
#
# Skipped on variants without the SB server (SKIP_SIDEBUTTON_SERVER=1): the
# reporter grabs the frame via the SB server's /api/screenshot endpoint, which
# those variants do not run.

step "Step 19c/16: Health + screenshot reporter (sb-health timer)"

if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  log "sb-health reporter skipped (SKIP_SIDEBUTTON_SERVER=1 — variant has no /api/screenshot)"
else
  # The reporter crops the focused Claude Code window (per-session terminal frame)
  # with xdotool + import (SCRUM-1414). xdotool is installed at provision in
  # base/02-system.sh, but this step is refresh-safe (refresh-manifest.txt) so it
  # also runs on already-provisioned boxes where 02 never re-runs. Idempotent
  # guard: install xdotool once on those boxes so the terminal frame lights up on
  # the next sb-self-update tick. Never fatal — a missing tool just skips the frame.
  if ! command -v xdotool >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y xdotool >/dev/null 2>&1 \
      && log "xdotool installed (terminal-window capture dep)" \
      || log "WARN: xdotool install failed — terminal frame skipped until reprovision"
  fi

  REPORTER_SRC="${BASE_DIR}/assets/report-health-snapshot.sh"
  REPORTER_DEST="/opt/report-health-snapshot.sh"

  if [ ! -f "$REPORTER_SRC" ]; then
    log "WARN: bundled reporter missing (${REPORTER_SRC}) — sb-health not installed"
  else
    install -m 0755 "$REPORTER_SRC" "$REPORTER_DEST"
    log "reporter installed: ${REPORTER_DEST}"

    # Oneshot service — runs as the agent user with the agent env (sb_token +
    # name). ExecStartPre is a bounded readiness gate (~120s) on the SB
    # screenshot endpoint so the first report carries a painted desktop; it
    # always exits 0 so a not-yet-ready server never blocks the report itself.
    cat > /etc/systemd/system/sb-health.service <<'EOF'
[Unit]
Description=SideButton agent health + screenshot reporter
After=sidebutton.service chrome.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=agent
EnvironmentFile=/home/agent/.agent-env
Environment=DISPLAY=:10
TimeoutStartSec=300
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf --max-time 2 http://localhost:9876/api/screenshot >/dev/null 2>&1 && exit 0; sleep 2; done; exit 0'
ExecStart=/opt/report-health-snapshot.sh --full
EOF

    # Timer — first push ~30s after every boot, then every 5 minutes.
    cat > /etc/systemd/system/sb-health.timer <<'EOF'
[Unit]
Description=Run the SideButton health reporter at boot and every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now sb-health.timer >/dev/null 2>&1 \
      || log "WARN: failed to enable sb-health.timer"
    # Immediate first push (install runs post-boot, so OnBootSec won't fire now).
    # --no-block so the readiness wait doesn't stall the installer.
    systemctl start --no-block sb-health.service 2>/dev/null \
      || log "WARN: failed to start sb-health.service"
    log "sb-health enabled (first push at boot+30s, then every 5min; +immediate push now)"
  fi
fi
