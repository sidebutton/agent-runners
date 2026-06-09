# components/openvpn/install.sh — OpenVPN client (MVP: profile applied manually).
#
# Sourced by base/run.sh when `openvpn` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs the open-source OpenVPN client (which ships the
# openvpn-client@.service template) + the `sb-vpn-connect` helper, so an operator
# can attach the customer .ovpn post-provision in one idempotent command:
#
#     sudo sb-vpn-connect /path/to/profile.ovpn
#
# The .ovpn carries an inline private key (a secret), so it is delivered out-of-band
# by the operator, NOT baked into the image / cloud-init. Idempotent.

step "Component: OpenVPN client"
if command -v openvpn >/dev/null 2>&1; then
  log "openvpn already installed: $(openvpn --version 2>/dev/null | head -n1)"
else
  apt-get install "${APT_OPTS[@]}" openvpn || log "WARN: openvpn install failed"
fi

# Install the smart helper next to it (heartbeat-safe, idempotent connect).
if [ -f "$BASE_DIR/components/openvpn/sb-vpn-connect" ]; then
  install -m 0755 "$BASE_DIR/components/openvpn/sb-vpn-connect" /usr/local/bin/sb-vpn-connect \
    && log "openvpn: sb-vpn-connect installed → run 'sudo sb-vpn-connect <profile.ovpn>' to attach the VPN" \
    || log "WARN: could not install sb-vpn-connect helper"
else
  log "WARN: sb-vpn-connect helper missing from component dir"
fi

log "openvpn: $(command -v openvpn >/dev/null 2>&1 && openvpn --version 2>/dev/null | head -n1 || echo not-installed)"
