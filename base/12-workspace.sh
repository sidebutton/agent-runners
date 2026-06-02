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

# Git credential helper for HTTPS clones/fetches/pushes of private workspace
# git-projects (e.g. maxsv0/the-assistant). Wrap `gh auth git-credential` in a
# shell that sources ~/.agent-env (set -a → export) at CALL time, so the helper
# always uses the current GH_TOKEN — not whatever was in the sidebutton.service
# process env at its single start (base/19b). systemd reads EnvironmentFile only
# at start, so without this a GH_TOKEN that lands or is corrected AFTER first boot
# (operator filling it per base/20, or an empty/failed secrets fetch fixed later)
# never reaches `gh`, and `git clone <private>` dies with:
#   fatal: could not read Username for 'https://github.com': terminal prompts disabled
GH_CRED_HELPER="!f(){ set -a; [ -f \"${AGENT_HOME}/.agent-env\" ] && . \"${AGENT_HOME}/.agent-env\"; set +a; exec /usr/bin/gh auth git-credential \"\$@\"; }; f"
git config -f "$AGENT_HOME/.gitconfig" credential.helper "$GH_CRED_HELPER" || true
