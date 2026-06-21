# 08-sidebutton.sh — SideButton MCP server + the fleet self-update wrapper.
#
# The SB server install is skipped when SKIP_SIDEBUTTON_SERVER=1 — set by the
# early-setup hook of variants that don't ship a server (e.g. ubuntu-claude-code,
# where the fleet job client takes the server's place in the dispatch chain).
#
# The self-update wrapper + its narrow NOPASSWD sudoers rule are installed on
# EVERY agent, though. Since SCRUM-1380 sb-self-update is not just an npm-server
# updater: it is the fleet's one self-service path and it ALSO refreshes the base
# artifacts (Claude hooks, step-script timers, ~/.local/bin helpers) that every
# agent has — server or serverless. Its npm-server half self-gates on
# `command -v sidebutton`, so it stays a no-op on serverless boxes.

if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  step "Step 8/16: SideButton MCP (server skipped — SKIP_SIDEBUTTON_SERVER=1)"
else
  step "Step 8/16: SideButton MCP"
  if ! command -v sidebutton >/dev/null 2>&1; then
    npm install -g sidebutton >/dev/null
  fi
  log "sidebutton: $(sidebutton --version 2>/dev/null || echo installed)"
fi

# --- self-update path (installed on all agents) ------------------------------
# The server is a root-owned global npm package (/usr/lib/node_modules) and base
# artifacts are root-written into agent-owned paths, but the agent user — which
# runs the agent_pull_repos ops job — is non-root and cannot touch either. Install
# a tiny root-owned wrapper + a NARROW NOPASSWD sudoers rule scoped to ONLY that
# wrapper, so the ops job can self-update without granting the agent broad sudo.
# The wrapper (base/assets/sb-self-update.sh) is idempotent and change-gated:
# it restarts the service / rewrites an artifact ONLY when something actually
# changed, so repeat pull_repos runs never bounce a current agent.
WRAPPER_SRC="${BASE_DIR}/assets/sb-self-update.sh"
if [ -f "$WRAPPER_SRC" ]; then
  install -m 0755 "$WRAPPER_SRC" /usr/local/bin/sb-self-update
  log "sb-self-update wrapper installed (npm CLI + base-artifact refresh)"
else
  log "WARN: sb-self-update asset missing (${WRAPPER_SRC}) — fleet self-update disabled"
fi

cat > /etc/sudoers.d/sb-self-update <<EOF
# Let the agent run the fleet self-update wrapper (upgrade the SideButton CLI and
# refresh base artifacts, restarting only on change) without a password — scoped
# to this one wrapper only.
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/sb-self-update
EOF
chmod 0440 /etc/sudoers.d/sb-self-update
if visudo -cf /etc/sudoers.d/sb-self-update >/dev/null 2>&1; then
  log "sb-self-update: narrow sudoers installed"
else
  rm -f /etc/sudoers.d/sb-self-update
  log "WARN: sb-self-update sudoers failed validation — removed (agent self-update disabled)"
fi
