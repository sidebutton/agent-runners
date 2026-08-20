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

# Bind the API on all interfaces so the relay/Temporal worker can reach it at
# the VM's private IP (firewall locks 9876 to the relay — see cloud/aws-sg.ts).
# The server now defaults to loopback and refuses a wide bind without a token,
# so this explicit opt-in pairs with the provisioned SIDEBUTTON_AGENT_TOKEN; if
# the token isn't written yet the server fails safe rather than running tokenless
# on 0.0.0.0 (SCRUM-1490).
SIDEBUTTON_HOST=0.0.0.0

# Required: Anthropic API key for Claude
ANTHROPIC_API_KEY=

# Required: Git credentials
GIT_USER_NAME=
GIT_USER_EMAIL=
GH_TOKEN=

# Optional: non-GitHub git hosts for workspace projects (delivered via per-agent
# secrets / agent_env), wired as a per-host credential helper below. BITBUCKET_API_TOKEN
# is an Atlassian API token; git over HTTPS authenticates with the magic username
# `x-bitbucket-api-token-auth` + that token (set by the helper below). BITBUCKET_USER_EMAIL
# and BITBUCKET_AUTH_HEADER (= base64(email:token)) are the REST-API form of the same token.
BITBUCKET_AUTH_HEADER=
BITBUCKET_USER_EMAIL=
BITBUCKET_API_TOKEN=

# Optional: per-account portal-hosted knowledge-pack registry token, delivered by
# the secrets fetch for mode=default packs. It is the HTTP-Basic password (username
# x-access-token) for the portal registry host (git.sidebutton.com-style) and is
# wired as a per-host credential helper below for clones, pulls and SD write-back pushes.
SIDEBUTTON_DEFAULT_REGISTRY_TOKEN=

# Jira credentials are PORTAL-OWNED and deliberately NOT scaffolded here. An api_key
# account's secrets fetch (base/19) appends the canonical JIRA_* set; a Forge-app
# account's agents pull a short-lived Bearer token per session instead
# (GET /api/agents/jira-token — the-assistant docs/plans/JIRA-AGENT-VM-ACCESS.md §4)
# and no Jira key ever lands in this file. Empty KEY= scaffold lines are a trap, not
# a hint: job preambles `source` this file over the daemon env, and a line saying
# JIRA_URL= BLANKS an inherited value that omitting the key would have let through.
# (JIRA_PROJECT_KEY is workspace-scoped and delivered by workspace applies — a
# hardcoded default here was wrong for every non-SCRUM tenant.)

# Populated by heartbeat below (DNS hostname assigned by portal)
AGENT_DNS=
EOF
  chmod 600 "$ENV_FILE"
fi

# Backfill SIDEBUTTON_HOST for agents provisioned before this knob existed, so a
# server upgrade that now defaults to loopback keeps binding wide on the existing
# fleet (idempotent — new installs already have it from the template above).
if [ -f "$ENV_FILE" ] && ! grep -q '^SIDEBUTTON_HOST=' "$ENV_FILE"; then
  printf 'SIDEBUTTON_HOST=0.0.0.0\n' >> "$ENV_FILE"
fi

if ! grep -q 'agent-env' "$AGENT_HOME/.bashrc" 2>/dev/null; then
  echo '[ -f ~/.agent-env ] && set -a && . ~/.agent-env && set +a' >> "$AGENT_HOME/.bashrc"
fi


# Per-host git credential helpers (github / gitlab / bitbucket / portal registry)
# live in 12b-git-credential-helpers.sh. They are split out because they are pure,
# idempotent `git config` writes and therefore refresh-safe — 12b IS listed in
# refresh-manifest.txt so a helper added or fixed later reaches the EXISTING fleet,
# which this step (one-time workspace/user setup) can never do. run.sh sources 12b
# immediately after this step.
