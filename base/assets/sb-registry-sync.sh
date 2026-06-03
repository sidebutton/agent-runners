#!/bin/bash
# /opt/sb-registry-sync.sh
#
# Add or update the per-account knowledge-pack registry. Shared by the one-time
# install add (base/19d) and the recurring update timer (sb-registry-update.timer)
# so both authenticate a private registry repo identically.
#
# Usage: sb-registry-sync.sh add [registry-url]   # url falls back to $SIDEBUTTON_DEFAULT_REGISTRY
#        sb-registry-sync.sh update               # git-pull every configured git registry
#
# `add` clones the registry git repo once; `update` pulls the already-configured
# registries (no url needed) so agents pick up SD-pushed modules.
#
# Auth (optional): SIDEBUTTON_DEFAULT_REGISTRY_TOKEN from ~/.agent-env. The env
# file is sourced at CALL time — secrets land AFTER boot (base/19 / portal
# config-apply) and systemd reads its EnvironmentFile only at start, so reading
# ~/.agent-env on every run is what always sees the current token and dodges the
# could-not-read-Username timing failure class (cf. SCRUM-1122/1124, base/12).

set -uo pipefail

ACTION="${1:-update}"
ENV_FILE="${HOME:-/home/agent}/.agent-env"
log() { echo "$(date -Is) sb-registry-sync[$ACTION] $*"; }

# Source the agent env at call time (systemd EnvironmentFile format: KEY="VALUE").
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  log "WARN: $ENV_FILE not found — proceeding with process env only" >&2
fi

# When a dedicated registry token is provided, force it for the registry's git
# operations. The standing gh credential helper (base/12) answers github.com with
# GH_TOKEN — the agent's WORKSPACE token, which need not have access to the account
# registry repo — so we override the helper list for the git children that
# `sidebutton registry add|update` spawns. GIT_CONFIG_* is the highest-precedence
# config source and is inherited by those children; an empty credential.helper
# resets the inherited list, then ours (username x-access-token + the token)
# answers. The token is never written to git config or the registry URL — the
# helper reads it from the environment at call time, so rotation is picked up.
if [ -n "${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN:-}" ]; then
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="credential.helper"
  export GIT_CONFIG_VALUE_0=""
  export GIT_CONFIG_KEY_1="credential.helper"
  export GIT_CONFIG_VALUE_1='!f(){ echo "username=x-access-token"; echo "password=${SIDEBUTTON_DEFAULT_REGISTRY_TOKEN}"; }; f'
  export GIT_TERMINAL_PROMPT=0
fi

case "$ACTION" in
  add)
    REGISTRY_URL="${2:-${SIDEBUTTON_DEFAULT_REGISTRY:-}}"
    if [ -z "$REGISTRY_URL" ]; then
      log "ERROR: no registry url (arg or \$SIDEBUTTON_DEFAULT_REGISTRY)" >&2
      exit 2
    fi
    log "adding registry: ${REGISTRY_URL}"
    sidebutton registry add "$REGISTRY_URL"
    ;;
  update)
    # Reconcile-then-pull (SCRUM-1167). The one-shot `add` in base/19d can fail
    # transiently — the registry credential (SIDEBUTTON_DEFAULT_REGISTRY_TOKEN, or the
    # GH_TOKEN the gh helper uses for own-repo accounts) lands in ~/.agent-env only after
    # a later config-apply, so an add that ran before the token arrived leaves the agent
    # with NO registry. Historically this timer only ran `update`, which pulls already-
    # configured registries and therefore never re-adds the missing one — so the account
    # registry stayed absent forever. Add-if-missing here heals that on the next tick.
    if [ -n "${SIDEBUTTON_DEFAULT_REGISTRY:-}" ] \
       && ! sidebutton registry list 2>/dev/null | grep -qF "$SIDEBUTTON_DEFAULT_REGISTRY"; then
      log "configured registry absent — reconciling (add ${SIDEBUTTON_DEFAULT_REGISTRY})"
      sidebutton registry add "$SIDEBUTTON_DEFAULT_REGISTRY" \
        || log "WARN: reconcile add failed — will retry next tick"
    fi
    log "updating git registries (git pull)"
    sidebutton registry update
    ;;
  *)
    log "ERROR: unknown action '$ACTION' (expected add|update)" >&2
    exit 2
    ;;
esac
