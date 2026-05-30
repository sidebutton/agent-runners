# 07-claude-code.sh — Claude Code CLI.

step "Step 7/16: Claude Code CLI"
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code >/dev/null
fi
log "claude: $(claude --version 2>/dev/null || echo installed)"
