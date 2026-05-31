# 12-workspace.sh — Workspace directories + .agent-env template + bashrc hook.

step "Step 12/16: Workspace + .agent-env template"
ENV_FILE="$AGENT_HOME/.agent-env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
# SideButton Agent Environment — populated by install.sh
# systemd EnvironmentFile format: KEY=VALUE — NO 'export' and NO shell
# expansion. sidebutton.service loads this file directly; with 'export' or
# \${VAR} references systemd logs "Ignoring invalid environment assignment" and
# the server boots with none of these vars (no GH_TOKEN, no sb_token, etc.).
# .bashrc re-sources this with 'set -a' so interactive shells export them too.

# Bootstrap identity (from install)
AGENT_TOKEN="${AGENT_TOKEN}"
AGENT_NAME="${AGENT_NAME}"
AGENT_ROLE="${AGENT_ROLE}"
PORTAL_URL="${PORTAL_URL}"

# SIDEBUTTON_* names used by hooks + the server. Baked to literal values (not
# \${AGENT_TOKEN}) because systemd does not expand. base/18 swaps both the
# AGENT_TOKEN and SIDEBUTTON_AGENT_TOKEN values to the sb_token on first heartbeat.
SIDEBUTTON_AGENT_TOKEN="${AGENT_TOKEN}"
SIDEBUTTON_AGENT_NAME="${AGENT_NAME}"

# Required: Anthropic API key for Claude
ANTHROPIC_API_KEY=

# Required: Git credentials
GIT_USER_NAME=
GIT_USER_EMAIL=
GH_TOKEN=

# Required for SE/QA agents: Jira credentials
JIRA_URL=
JIRA_EMAIL=
JIRA_API_TOKEN=
JIRA_PROJECT_KEY=SCRUM

# Populated by heartbeat below (DNS hostname assigned by portal)
AGENT_DNS=
EOF
  chmod 600 "$ENV_FILE"
fi

if ! grep -q 'agent-env' "$AGENT_HOME/.bashrc" 2>/dev/null; then
  echo '[ -f ~/.agent-env ] && set -a && . ~/.agent-env && set +a' >> "$AGENT_HOME/.bashrc"
fi

git config -f "$AGENT_HOME/.gitconfig" credential.helper '!/usr/bin/gh auth git-credential' || true
