# components/claude-code/install.sh — Claude Code agentic CLI (default agent runtime).
#
# Sourced by base/run.sh when INSTALL_CLAUDE_CODE=1. That gate (base/components.sh)
# is DEFAULT-ON: it resolves to 1 whenever `claude-code` is in AGENT_COMPONENTS OR
# the set is empty/unset (manual / back-compat), so a base agent still ships Claude
# Code. An explicit non-empty set that omits `claude-code` skips this install.
# Runs as root at provision time, at the SAME position as the former step — before
# the Claude-config steps (09/14/15/15b) which stay in base, ungated.
# Idempotent (the `command -v claude` guard).
#
# Body moved from the former base/07-claude-code.sh (SCRUM-1445); the "Step 7/16"
# label is preserved for that parity. The version now comes from the sibling
# `version` file — `latest` by default, which is exactly the old unpinned install —
# so a new agent lands on the same Claude Code the live fleet converges on through
# sb-self-update (lib-refresh.sh sb_refresh_claude_code).

step "Step 7/16: Claude Code CLI"
if ! command -v claude >/dev/null 2>&1; then
  CLAUDE_CODE_WANT="$(sed -e 's/#.*$//' "${BASE_DIR:-}/components/claude-code/version" 2>/dev/null | awk 'NF {print $1; exit}' || true)"
  npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_WANT:-latest}" >/dev/null
fi
log "claude: $(claude --version 2>/dev/null || echo installed)"
