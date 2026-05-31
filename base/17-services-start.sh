# 17-services-start.sh — daemon-reload, enable, start the desktop services, chown.
#
# sidebutton.service is ENABLED here but STARTED later (base/19b), once base/18
# has swapped in the permanent sb_token and base/19 has written the secrets — so
# the server reads a complete ~/.agent-env on its first and only start (no stale-
# token window, no restart). systemd reads the EnvironmentFile only at start.
#
# Variants that don't ship the SB server (SKIP_SIDEBUTTON_SERVER=1) drop
# sidebutton.service from the enable list — the unit doesn't exist (see step 16).
# Replacement services (e.g. fleet-job-client.service for ubuntu-claude-code) are
# enabled/started by the variant's post-services hook.

systemctl daemon-reload
if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  systemctl enable xvfb xfce-session x11vnc chrome >/dev/null
else
  systemctl enable xvfb xfce-session x11vnc chrome sidebutton >/dev/null
fi
systemctl restart xrdp
systemctl start xvfb
sleep 1
systemctl start xfce-session
sleep 2
systemctl start x11vnc
sleep 1
# sidebutton.service is intentionally NOT started here — base/19b starts it once
# the permanent token + secrets are in ~/.agent-env (see header). The Chrome
# extension reconnects on its own once the server comes up.
systemctl start chrome || log "WARN: chrome service failed to start"

chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
