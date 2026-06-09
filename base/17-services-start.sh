# 17-services-start.sh — daemon-reload, enable, start the desktop services, chown.
#
# sidebutton.service is ENABLED here but STARTED later (base/19b), once base/18
# has swapped in the permanent sb_token and base/19 has written the secrets — so
# the server reads a complete ~/.agent-env on its first and only start (no stale-
# token window, no restart). systemd reads the EnvironmentFile only at start.
#
# Component-gated: `chrome` (INSTALL_CHROME) and `sidebutton-server`
# (SKIP_SIDEBUTTON_SERVER) only join the enable/start list when selected — their
# units are written conditionally in step 16.

systemctl daemon-reload
ENABLE_UNITS="xvfb xfce-session x11vnc"
[ "${INSTALL_CHROME:-1}" = "1" ] && ENABLE_UNITS="$ENABLE_UNITS chrome"
[ "${SKIP_SIDEBUTTON_SERVER:-}" != "1" ] && ENABLE_UNITS="$ENABLE_UNITS sidebutton"
# shellcheck disable=SC2086
systemctl enable $ENABLE_UNITS >/dev/null
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
if [ "${INSTALL_CHROME:-1}" = "1" ]; then
  systemctl start chrome || log "WARN: chrome service failed to start"
fi

chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
