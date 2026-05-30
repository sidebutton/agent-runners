# 08-sidebutton.sh — SideButton MCP server.

step "Step 8/16: SideButton MCP"
if ! command -v sidebutton >/dev/null 2>&1; then
  npm install -g sidebutton >/dev/null
fi
log "sidebutton: $(sidebutton --version 2>/dev/null || echo installed)"
