# 17-services-start.sh — daemon-reload, enable, start services, final chown.
#
# Variants that don't ship the SB server (SKIP_SIDEBUTTON_SERVER=1) drop
# sidebutton.service from the enable/start list — the unit doesn't exist
# (see step 16). Replacement services (e.g. fleet-job-client.service for
# ubuntu-claude-code) are enabled/started by the variant's post-services hook.

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
if [ "${SKIP_SIDEBUTTON_SERVER:-}" != "1" ]; then
  systemctl start sidebutton
  sleep 2
fi
systemctl start chrome || log "WARN: chrome service failed to start"

chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
