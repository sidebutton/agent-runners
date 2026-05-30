# 17-services-start.sh — daemon-reload, enable, start services, final chown.

systemctl daemon-reload
systemctl enable xvfb xfce-session x11vnc chrome sidebutton >/dev/null
systemctl restart xrdp
systemctl start xvfb
sleep 1
systemctl start xfce-session
sleep 2
systemctl start x11vnc
sleep 1
systemctl start sidebutton
sleep 2
systemctl start chrome || log "WARN: chrome service failed to start"

chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
