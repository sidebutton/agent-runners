# 15b-claude-onboarding.sh — pre-complete Claude Code's first-run onboarding.
#
# Claude Code shows an interactive first-run flow (theme picker, etc.) gated on
# `hasCompletedOnboarding` in ~/.claude.json. 07 installs the CLI and 15 runs
# `claude mcp add` (a non-interactive subcommand, so provisioning never blocks),
# but neither marks onboarding complete. The first time anything launches claude
# INTERACTIVELY — e.g. the agent_pull_repos ops workflow runs
# `claude --dangerously-skip-permissions "<prompt>"` in a visible terminal — it
# drops into the theme-picker TUI and hangs, since --dangerously-skip-permissions
# bypasses tool/trust prompts but NOT onboarding. Seed the flags so agents start
# straight into work unattended (auth is already satisfied by ANTHROPIC_API_KEY
# in ~/.agent-env, so no login step remains).
#
# Not gated by SKIP_SIDEBUTTON_SERVER — the onboarding TUI affects every variant
# that ships Claude Code (incl. ubuntu-claude-code). jq is installed by 02-system;
# the merge preserves the mcpServers entry 15 wrote and is safe to re-run.

step "Step 15b/16: Pre-complete Claude Code onboarding"
CLAUDE_JSON="${AGENT_HOME}/.claude.json"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp="$(mktemp)"
if jq '. + {hasCompletedOnboarding: true, hasCompletedProjectOnboarding: true, theme: "dark"}' \
     "$CLAUDE_JSON" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$CLAUDE_JSON"
else
  rm -f "$tmp"
  log "WARN: could not seed Claude Code onboarding flags in $CLAUDE_JSON"
fi
chown "${AGENT_USER}:${AGENT_USER}" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON"
log "claude onboarding pre-completed (hasCompletedOnboarding, theme=dark)"
