# 12b-git-credential-helpers.sh — per-host git credential helpers.
#
# Split out of 12-workspace.sh (which stays install-only: dirs, .agent-env
# template, bashrc hook) for ONE reason: these helpers are pure, idempotent
# `git config` writes, so unlike the rest of 12 they are safe to re-run on a
# live agent — and they MUST be, or a helper added/fixed after an agent was
# provisioned never reaches the existing fleet. This step is therefore listed in
# refresh-manifest.txt; 12 is not. Same carve-out shape as 15b.
#
# THE INVARIANT EVERY HELPER BELOW SHARES: each one sources ~/.agent-env at CALL
# time (`set -a` → export) instead of trusting the ambient process env, so it
# always uses the CURRENT token. systemd reads EnvironmentFile only at unit
# start, so a token that lands or is corrected AFTER first boot — an operator
# filling it in per base/20, a rotation, an empty/failed secrets fetch fixed
# later — would otherwise never reach git, and the clone dies with:
#   fatal: could not read Username for 'https://<host>': terminal prompts disabled
# That call-time sourcing is also what makes rotation a no-op here: no login is
# stored, nothing to re-auth, no reboot. No token is ever written to .gitconfig.

step "Step 12b/16: Git credential helpers"

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

# GitLab HTTPS credential helper for gitlab.com workspace git-projects. The global
# `gh` helper above answers github.com only, so without this git has NO credential
# source for gitlab.com and a private clone dies with "could not read Username"
# (the exact break this step was written for). Uses the agent's OWN env credential:
# GITLAB_TOKEN is the RESERVED operator-set name the portal never writes and never
# strips (the-assistant lib/cloud/gitlab-agent-env.ts) — the portal's own connected
# PAT is a read credential and must NEVER be what pushes.
#
# Deliberately does NOT shell out to `glab auth git-credential` (the gh-shaped
# option). `glab` IS installed on every agent (03b-glab-cli.sh, SCRUM-1958), but
# routing through it would require a STORED `glab auth login` — state that can go
# stale against ~/.agent-env, needs --insecure-storage to stay readable from
# systemd/cron, and cannot be registered until a token exists (so it re-opens the
# provision-order race this whole step exists to close). Answering the credential
# protocol directly is stateless: no login, no hosts.yml, no keyring, and a token
# dropped in at ANY later time works on the very next git command. `glab` stays
# what it is good for — `glab mr create`, which reads GITLAB_TOKEN from the env
# that job preambles already source.
#
# `username=oauth2` with the PAT as the password is VERIFIED against gitlab.com's
# smart-HTTP endpoint (info/refs returns 200 with a valid token, 401 with a bad
# one). Sourced at call time (rotation-safe; token never written to .gitconfig).
# The empty `--replace-all` resets the inherited (gh) helper for this host so only
# ours answers it — same reason as the Bitbucket pair above.
GL_CRED_HELPER="!f(){ set -a; [ -f \"${AGENT_HOME}/.agent-env\" ] && . \"${AGENT_HOME}/.agent-env\"; set +a; [ \"\$1\" = get ] || exit 0; [ -n \"\${GITLAB_TOKEN}\" ] || exit 0; printf 'username=oauth2\npassword=%s\n' \"\${GITLAB_TOKEN}\"; }; f"
git config -f "$AGENT_HOME/.gitconfig" --replace-all credential.https://gitlab.com.helper "" || true
git config -f "$AGENT_HOME/.gitconfig" --add         credential.https://gitlab.com.helper "$GL_CRED_HELPER" || true

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

# `git config -f` rewrites the file via temp+rename, so a root-run refresh would
# leave ~/.gitconfig owned by root — after which the agent user can no longer run
# `git config --global`. Provisioning never hit this (12 ran before the file had an
# owner to lose); the refresh path does, so hand it back explicitly.
chown "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME/.gitconfig" 2>/dev/null || true

log "git credential helpers configured (github, gitlab, bitbucket$([ -n "${REG_HOST:-}" ] && printf ', %s' "$REG_HOST"))"
