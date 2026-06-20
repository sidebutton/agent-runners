# 08-sidebutton.sh — SideButton MCP server.
#
# Skipped when SKIP_SIDEBUTTON_SERVER=1 — set by the early-setup hook of
# variants that don't ship a server (e.g. ubuntu-claude-code, where the
# fleet job client takes the server's place in the dispatch chain).

if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  step "Step 8/16: SideButton MCP (skipped — SKIP_SIDEBUTTON_SERVER=1)"
else
  step "Step 8/16: SideButton MCP"
  if ! command -v sidebutton >/dev/null 2>&1; then
    npm install -g sidebutton >/dev/null
  fi
  log "sidebutton: $(sidebutton --version 2>/dev/null || echo installed)"

  # --- self-update path ----------------------------------------------------
  # The server is a root-owned global npm package (/usr/lib/node_modules), but the
  # agent user — which runs the agent_pull_repos ops job — is non-root and cannot
  # write there. Without a path to upgrade it, the CLI/server is frozen at whatever
  # npm `latest` was when the VM was first provisioned and silently drifts behind.
  # Install a tiny root-owned wrapper + a NARROW NOPASSWD sudoers rule scoped to
  # ONLY that wrapper, so the ops job can pull `sidebutton@latest` without granting
  # the agent broad sudo. The wrapper is idempotent and restarts the service ONLY
  # when the version actually changed, so repeat pull_repos runs never bounce a
  # current agent.
  cat > /usr/local/bin/sb-self-update <<'EOF'
#!/usr/bin/env bash
# sb-self-update — upgrade the global SideButton CLI/server to the latest npm
# release; restart sidebutton.service iff the version changed. Idempotent: a
# no-op (no restart) when already current. Run as root via sudoers by the agent.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
before="$(sidebutton --version 2>/dev/null || echo none)"
if ! npm install -g sidebutton@latest >/dev/null 2>&1; then
  echo "sb-self-update: npm install failed"; exit 1
fi
after="$(sidebutton --version 2>/dev/null || echo none)"
if [ "$before" != "$after" ]; then
  systemctl restart sidebutton 2>/dev/null || true
  echo "sb-self-update: upgraded ${before} -> ${after} (sidebutton.service restarted)"
else
  echo "sb-self-update: already at ${after} (no change)"
fi
EOF
  chmod 0755 /usr/local/bin/sb-self-update

  cat > /etc/sudoers.d/sb-self-update <<EOF
# Let the agent upgrade the SideButton CLI/server to the latest npm release (and
# restart the service) without a password — scoped to this one wrapper only.
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/sb-self-update
EOF
  chmod 0440 /etc/sudoers.d/sb-self-update
  if visudo -cf /etc/sudoers.d/sb-self-update >/dev/null 2>&1; then
    log "sb-self-update: wrapper + narrow sudoers installed"
  else
    rm -f /etc/sudoers.d/sb-self-update
    log "WARN: sb-self-update sudoers failed validation — removed (agent self-update disabled)"
  fi
fi
