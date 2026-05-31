# pre-services.sh — variant overlay (ubuntu-claude-code)
#
# Install the fleet job client binary + systemd unit BEFORE 17-services-start.sh
# enables/starts services. The unit slots into the same role sidebutton.service
# fills on the other variants: an always-on HTTP listener on :9876 that the
# portal's Temporal dispatch hits via /api/workflows/<id>/run.

FJC_SRC="${RUNNERS_ROOT:-}/fleet-job-client/bin/fleet-job-client.mjs"
FJC_BIN="/usr/local/bin/fleet-job-client.mjs"

if [ ! -f "$FJC_SRC" ]; then
  die "fleet-job-client source not found at ${FJC_SRC} (RUNNERS_ROOT=${RUNNERS_ROOT:-unset})"
fi

install -m 0755 "$FJC_SRC" "$FJC_BIN"
log "fleet-job-client installed: $FJC_BIN"

cat > /etc/systemd/system/fleet-job-client.service <<EOF
[Unit]
Description=Fleet Job Client (bare Claude Code dispatch endpoint)
After=network.target xfce-session.service
Requires=xvfb.service

[Service]
Type=simple
User=${AGENT_USER}
WorkingDirectory=${AGENT_HOME}/workspace
EnvironmentFile=${AGENT_HOME}/.agent-env
Environment=DISPLAY=:10
Environment=FLEET_CLIENT_PORT=9876
Environment=AGENT_RUNNER=${AGENT_RUNNER}
Environment=RUNNERS_REF=${RUNNERS_REF}
ExecStart=/usr/bin/node ${FJC_BIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
log "fleet-job-client.service unit written"
