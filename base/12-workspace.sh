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

# Bitbucket HTTPS credential helper for non-GitHub workspace git-projects (e.g.
# tusmediadevelopers/*). The global `gh` helper above only answers github.com. Uses the
# agent's OWN env credential — no portal token is ever sent to the agent.
# BITBUCKET_API_TOKEN is an Atlassian API token. For git over HTTPS, Bitbucket requires the
# magic username `x-bitbucket-api-token-auth` with the API token as the password — VERIFIED
# against a live repo (ls-remote returns refs). The account email (used for the REST API and
# baked into BITBUCKET_AUTH_HEADER) is REJECTED by git with HTTP 401, so do NOT use it here.
# Sourced at call time (rotation-safe; token never written to .gitconfig). The empty
# `--replace-all` resets the inherited (gh) helper for this host so only ours answers it.
BB_CRED_HELPER="!f(){ set -a; [ -f \"${AGENT_HOME}/.agent-env\" ] && . \"${AGENT_HOME}/.agent-env\"; set +a; [ \"\$1\" = get ] || exit 0; [ -n \"\${BITBUCKET_API_TOKEN}\" ] || exit 0; printf 'username=x-bitbucket-api-token-auth\npassword=%s\n' \"\${BITBUCKET_API_TOKEN}\"; }; f"
git config -f "$AGENT_HOME/.gitconfig" --replace-all credential.https://bitbucket.org.helper "" || true
git config -f "$AGENT_HOME/.gitconfig" --add         credential.https://bitbucket.org.helper "$BB_CRED_HELPER" || true

# Portal-hosted account knowledge-pack registry HTTPS credential helper. When the
# account's pack repo is the SideButton-hosted default (SIDEBUTTON_DEFAULT_REGISTRY
# points at git.sidebutton.com), SD's write-back is a plain `git push` to it, and the
# gh/Bitbucket helpers above don't answer that host. Scope a per-host helper that
# authenticates with the per-account token delivered to ~/.agent-env
# (SIDEBUTTON_DEFAULT_REGISTRY_TOKEN) using the smart-HTTP x-access-token username. The
# pull side (registry add/update) already forces the same token via
# /opt/sb-registry-sync.sh's GIT_CONFIG_* override; this closes the push side.
# Sourced at call time (rotation-safe; token never written to .gitconfig). The empty
# --replace-all resets the inherited (gh) helper for this host so only ours answers it.
#
# ALLOWLIST, not denylist: wire this ONLY for the SideButton-hosted host. An own-repo
# provider (github.com / bitbucket.org / gitlab.com / self-hosted) must clone+push with
# the agent's OWN credential via the gh/Bitbucket helpers above and must NEVER receive
# the portal token — so a future own-GitLab account can't fall through to it. (Belt &
# suspenders: secrets.ts only delivers SIDEBUTTON_DEFAULT_REGISTRY_TOKEN for mode=default
# accounts, so the helper also self-guards on token presence.) Prod portal host is
# git.sidebutton.com (GIT_HOST_PUBLIC_BASE default); a white-label deploy overriding that
# base extends the match below — or the portal forwards the pack mode explicitly.
REG_URL="${SIDEBUTTON_DEFAULT_REGISTRY:-}"
case "$REG_URL" in
  https://*)
    REG_HOST="${REG_URL#https://}"; REG_HOST="${REG_HOST%%/*}"
    case "$REG_HOST" in
      sidebutton.com|*.sidebutton.com)  # SideButton-hosted default registry only
        REG_CRED_HELPER="!f(){ set -a; [ -f \"${AGENT_HOME}/.agent-env\" ] && . \"${AGENT_HOME}/.agent-env\"; set +a; [ \"\$1\" = get ] || exit 0; [ -n \"\${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN}\" ] || exit 0; printf 'username=x-access-token\npassword=%s\n' \"\${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN}\"; }; f"
        git config -f "$AGENT_HOME/.gitconfig" --replace-all "credential.https://${REG_HOST}.helper" "" || true
        git config -f "$AGENT_HOME/.gitconfig" --add         "credential.https://${REG_HOST}.helper" "$REG_CRED_HELPER" || true
        log "portal registry credential helper configured for https://${REG_HOST}"
        ;;
      *)  # own-repo provider (github/bitbucket/gitlab/self-hosted) — its own helper handles auth
        log "registry host ${REG_HOST:-<none>} is not portal-hosted — leaving its own (gh/Bitbucket) helper to authenticate"
        ;;
    esac
    ;;
esac
