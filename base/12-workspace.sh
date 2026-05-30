# 12-workspace.sh — Workspace directories + .agent-env template + bashrc hook.

step "Step 12/16: Workspace + .agent-env template"
ENV_FILE="$AGENT_HOME/.agent-env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
# SideButton Agent Environment — populated by install.sh
# Fill in placeholder values (ANTHROPIC_API_KEY, GH_TOKEN, JIRA_*), then re-source.

# Bootstrap identity (from install)
export AGENT_TOKEN="${AGENT_TOKEN}"
export AGENT_NAME="${AGENT_NAME}"
export AGENT_ROLE="${AGENT_ROLE}"
export PORTAL_URL="${PORTAL_URL}"

# Mirror the SIDEBUTTON_* names used by older hooks.
export SIDEBUTTON_AGENT_TOKEN="\${AGENT_TOKEN}"
export SIDEBUTTON_AGENT_NAME="\${AGENT_NAME}"

# Required: Anthropic API key for Claude
export ANTHROPIC_API_KEY=

# Required: Git credentials
export GIT_USER_NAME=
export GIT_USER_EMAIL=
export GH_TOKEN=

# Required for SE/QA agents: Jira credentials
export JIRA_URL=
export JIRA_EMAIL=
export JIRA_API_TOKEN=
export JIRA_PROJECT_KEY=SCRUM

# Populated by heartbeat below (DNS hostname assigned by portal)
export AGENT_DNS=
EOF
  chmod 600 "$ENV_FILE"
fi

if ! grep -q 'agent-env' "$AGENT_HOME/.bashrc" 2>/dev/null; then
  echo '[ -f ~/.agent-env ] && . ~/.agent-env' >> "$AGENT_HOME/.bashrc"
fi

git config -f "$AGENT_HOME/.gitconfig" credential.helper '!/usr/bin/gh auth git-credential' || true
