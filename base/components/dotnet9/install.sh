# components/dotnet9/install.sh — .NET 9 SDK (system-wide).
#
# Sourced by base/run.sh when `dotnet9` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs the SDK to /usr/lib/dotnet via the official
# dotnet-install script (provider-agnostic, version-exact; avoids the MS-apt-repo
# vs Ubuntu-feed conflict on 24.04) and symlinks it onto PATH. Idempotent.

step "Component: .NET 9 SDK"
if command -v dotnet >/dev/null 2>&1 && dotnet --version 2>/dev/null | grep -q '^9\.'; then
  log "dotnet 9 already installed: $(dotnet --version 2>/dev/null)"
else
  DOTNET_INSTALL_DIR=/usr/lib/dotnet
  mkdir -p "$DOTNET_INSTALL_DIR"
  if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused \
       https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; then
    bash /tmp/dotnet-install.sh --channel 9.0 --install-dir "$DOTNET_INSTALL_DIR" >>"$LOG_FILE" 2>&1 \
      || log "WARN: dotnet-install.sh failed"
    rm -f /tmp/dotnet-install.sh
    ln -sf "$DOTNET_INSTALL_DIR/dotnet" /usr/local/bin/dotnet
    # System-wide DOTNET_ROOT for login shells / tooling (the host also resolves
    # the SDK from the binary's own path, so this is belt-and-suspenders).
    grep -q '^DOTNET_ROOT=' /etc/environment 2>/dev/null \
      || echo "DOTNET_ROOT=${DOTNET_INSTALL_DIR}" >> /etc/environment
  else
    log "WARN: could not download dotnet-install.sh — .NET 9 not installed"
  fi
  log "dotnet: $(/usr/local/bin/dotnet --version 2>/dev/null || echo not-installed)"
fi
