# 15b-claude-onboarding.sh — pre-complete Claude Code's first-run prompts.
#
# Claude Code gates the first interactive run on two things in ~/.claude.json:
#   1. onboarding (theme picker)  — `hasCompletedOnboarding`
#   2. per-folder trust           — `projects[<dir>].hasTrustDialogAccepted`
#      ("Is this a project you trust?" on first entry to a directory)
# 07 installs the CLI and 15 runs `claude mcp add` (non-interactive, so
# provisioning never blocks), but neither marks these done. The first time
# anything launches claude INTERACTIVELY — e.g. the agent_pull_repos ops
# workflow runs `claude --dangerously-skip-permissions "<prompt>"` in a visible
# terminal — it stops at the theme picker, then (once past that) at the trust
# prompt for ~/workspace. --dangerously-skip-permissions bypasses tool prompts
# but NOT these first-run gates on this Claude Code version. Seed both so agents
# start straight into work unattended (auth is satisfied by ANTHROPIC_API_KEY /
# GH_TOKEN in ~/.agent-env).
#
# Not gated by SKIP_SIDEBUTTON_SERVER — these gates affect every variant that
# ships Claude Code. jq is installed by 02-system; the merge preserves the
# mcpServers entry 15 wrote and is safe to re-run. Trust is seeded for the
# standard agent work dirs (~/workspace, ~/ops, ~/oss).

step "Step 15b/16: Pre-complete Claude Code onboarding + folder trust"
CLAUDE_JSON="${AGENT_HOME}/.claude.json"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp="$(mktemp)"
if jq --arg h "$AGENT_HOME" '
      . + {hasCompletedOnboarding: true, hasCompletedProjectOnboarding: true, theme: "dark"}
      | .projects = (.projects // {})
      | .projects[$h + "/workspace"] = ((.projects[$h + "/workspace"] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})
      | .projects[$h + "/ops"]       = ((.projects[$h + "/ops"] // {})       + {hasTrustDialogAccepted: true})
      | .projects[$h + "/oss"]       = ((.projects[$h + "/oss"] // {})       + {hasTrustDialogAccepted: true})
    ' "$CLAUDE_JSON" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$CLAUDE_JSON"
else
  rm -f "$tmp"
  log "WARN: could not seed Claude Code onboarding/trust flags in $CLAUDE_JSON"
fi
chown "${AGENT_USER}:${AGENT_USER}" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON"
log "claude onboarding + folder trust pre-completed (~/workspace, ~/ops, ~/oss)"
