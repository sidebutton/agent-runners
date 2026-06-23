# components/rdp-client/install.sh — RDP client (FreeRDP) + sb-rdp-connect.
#
# Sourced by base/run.sh when `rdp-client` is in AGENT_COMPONENTS. Runs as root
# at provision time. Installs FreeRDP (xfreerdp) + the `sb-rdp-connect` helper and
# writes sb-rdp.service so an OUTBOUND RDP session to a customer host renders onto
# the agent's base display (:10) — driveable by the computer-use plugin, visible
# in LiveDesktop. The unit is left DISABLED: the target host + credentials are a
# per-customer secret applied out-of-band post-provision (like the VPN .ovpn) at
# /etc/sidebutton/rdp.env, then `systemctl enable --now sb-rdp`. Idempotent.
#
# NB: distinct from the INBOUND agent-login RDP password set in 19-secrets.sh
# (operators RDP *into* this VM). This component is the agent → customer session.

step "Component: RDP client (FreeRDP)"

if command -v xfreerdp >/dev/null 2>&1 || command -v xfreerdp3 >/dev/null 2>&1; then
  log "freerdp already installed: $(command -v xfreerdp xfreerdp3 2>/dev/null | head -n1)"
else
  # Ubuntu 24.04 ships freerdp2-x11 (binary: xfreerdp). Fall back to freerdp3-x11
  # (binary: xfreerdp3) on releases where freerdp2 is dropped; sb-rdp-connect
  # auto-selects whichever binary is present.
  apt-get install "${APT_OPTS[@]}" freerdp2-x11 \
    || apt-get install "${APT_OPTS[@]}" freerdp3-x11 \
    || log "WARN: freerdp install failed (need freerdp2-x11 or freerdp3-x11)"
fi

# Install the auto-reconnect helper. It is executed by sb-rdp.service as the
# `agent` user, so it must be agent-readable/executable → 0755 (as sb-vpn-connect).
if [ -f "$BASE_DIR/components/rdp-client/sb-rdp-connect" ]; then
  install -m 0755 "$BASE_DIR/components/rdp-client/sb-rdp-connect" /usr/local/bin/sb-rdp-connect \
    && log "rdp-client: sb-rdp-connect installed → drop /etc/sidebutton/rdp.env then 'sudo systemctl enable --now sb-rdp'" \
    || log "WARN: could not install sb-rdp-connect helper"
else
  log "WARN: sb-rdp-connect helper missing from component dir"
fi

# sb-rdp.service — renders the session on :10 (modeled on chrome.service from
# 16-services-prep.sh). Left DISABLED at provision (no secret yet); the helper
# itself idle-waits until /etc/sidebutton/rdp.env exists, so enabling it before
# the creds land is harmless.
mkdir -p /etc/sidebutton
cat > /etc/systemd/system/sb-rdp.service <<'EOF'
[Unit]
Description=SideButton outbound RDP session (FreeRDP on :10)
After=xfce-session.service x11vnc.service
Requires=xvfb.service

[Service]
Type=simple
User=agent
Environment=DISPLAY=:10
ExecStart=/usr/local/bin/sb-rdp-connect
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1 || true

log "rdp-client: $({ command -v xfreerdp || command -v xfreerdp3 ; } >/dev/null 2>&1 && echo installed || echo not-installed); sb-rdp.service written (disabled — drop /etc/sidebutton/rdp.env then 'systemctl enable --now sb-rdp')"
