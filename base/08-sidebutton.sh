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
fi
