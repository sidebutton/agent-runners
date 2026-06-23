# components/wireguard/install.sh — WireGuard client (MVP: profile applied manually).
#
# Sourced by base/run.sh when `wireguard` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs wireguard-tools (which ships `wg`, `wg-quick`, and the
# wg-quick@.service template) + the `sb-wg-connect` helper, so an operator can
# attach the customer .conf post-provision in one idempotent command:
#
#     sudo sb-wg-connect /path/to/profile.conf [name]
#
# The .conf carries an inline private key (+ optional preshared key) — a secret —
# so it is delivered out-of-band by the operator, NOT baked into the image /
# cloud-init. Idempotent. No tunnel connected at provision.
#
# wireguard-tools (NOT the DKMS `wireguard` metapackage) is the right dependency on
# Ubuntu 24.04: the kernel module has been in-tree since 5.6.

step "Component: WireGuard client"
if command -v wg >/dev/null 2>&1; then
  log "wireguard-tools already installed: $(wg --version 2>/dev/null | head -n1)"
else
  apt-get install "${APT_OPTS[@]}" wireguard-tools || log "WARN: wireguard-tools install failed"
fi

# Install the connect helper next to it (split-tunnel, idempotent connect).
if [ -f "$BASE_DIR/components/wireguard/sb-wg-connect" ]; then
  install -m 0755 "$BASE_DIR/components/wireguard/sb-wg-connect" /usr/local/bin/sb-wg-connect \
    && log "wireguard: sb-wg-connect installed → run 'sudo sb-wg-connect <profile.conf> [name]' to attach the tunnel" \
    || log "WARN: could not install sb-wg-connect helper"
else
  log "WARN: sb-wg-connect helper missing from component dir"
fi

log "wireguard: $(command -v wg >/dev/null 2>&1 && wg --version 2>/dev/null | head -n1 || echo not-installed)"
