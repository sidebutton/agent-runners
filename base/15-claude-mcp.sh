# 15-claude-mcp.sh — register the SideButton MCP transport in Claude Code.

step "Step 15/16: Register SideButton MCP"
chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
su - "$AGENT_USER" -c 'cd ~/workspace && claude mcp add sidebutton --transport sse http://localhost:9876/mcp -s project' 2>/dev/null \
  || log "WARN: claude mcp add failed — re-run as agent after login"
