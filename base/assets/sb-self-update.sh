#!/usr/bin/env bash
# sb-self-update — the agent fleet's single self-service update path (SCRUM-1380).
# Installed to /usr/local/bin/sb-self-update by base/08 and run as root via a
# narrow NOPASSWD sudoers rule scoped to ONLY this wrapper, by the agent_pull_repos
# ops job (`sudo sb-self-update`). It is the ONE privileged action the fleet has.
#
# All three of its idempotent, change-gated steps run from a SINGLE fresh download
# of agent-runners@<ref>, so a fix to the wrapper OR the shared lib reaches the
# fleet via this path itself:
#   1. Upgrade the global SideButton CLI/server npm package — disk-preflighted,
#      verified and self-repairing (lib-refresh.sh sb_refresh_server_cli), restarting
#      the service ONLY on a healthy version change. Gated on the sidebutton.service
#      unit, so a server box whose bin link was lost is REPAIRED, not mistaken for a
#      serverless box (the old `command -v sidebutton` gate latched it off forever).
#   2. Refresh the agent-runners BASE ARTIFACTS (Claude hooks, step-script timers,
#      ~/.local/bin helpers) — change-gated by a fingerprint vs /etc/sidebutton/updated.
#   3. Reconcile the universal "agents" CATALOG OPS PACK (rides step 2 via
#      sb_refresh_base_artifacts -> sb_refresh_knowledge_packs).
#
# A root sudo wrapper inherits no agent env, so it resolves the repo/ref itself
# from /etc/sidebutton/{updated,installed} and hands artifacts back to the agent.
#
# Step 1 USED to be an inline `npm install -g` here. It moved into base/lib-refresh.sh
# (shared with the operator break-glass agent-redeploy.sh) and was hardened after an
# ENOSPC mid-install stranded /usr/bin/sidebutton and bricked an agent on its next
# reboot — a 203/EXEC crash-loop the old inline step could not self-heal because its
# `command -v sidebutton` gate then treated the box as serverless (RCA 2026-06-28).
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LOG_FILE="${LOG_FILE:-/var/log/sidebutton-update.log}"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/${AGENT_USER}}"

# Resolve the ref the agent is pinned to (effective ref if a prior refresh wrote
# one, else the provision-time ref) and the source repo.
read_marker() { [ -r "$2" ] && sed -n "s/^$1=//p" "$2" | tail -1; }
RUNNERS_REF="$(read_marker runners_ref /etc/sidebutton/updated)"
[ -n "$RUNNERS_REF" ] || RUNNERS_REF="$(read_marker runners_ref /etc/sidebutton/installed)"
[ -n "$RUNNERS_REF" ] || RUNNERS_REF="main"
RUNNERS_REPO="$(read_marker runners_repo /etc/sidebutton/installed)"
[ -n "$RUNNERS_REPO" ] || RUNNERS_REPO="sidebutton/agent-runners"

RUNNERS_TMP="$(mktemp -d /tmp/agent-runners-selfupdate.XXXXXX)"
trap 'rm -rf "$RUNNERS_TMP"' EXIT

# ONE fetch of agent-runners@<ref> — the CLI upgrade (step 1) AND the base-artifact
# refresh (steps 2-3) both run from THIS tree. If the fetch fails, skip everything
# rather than run a half-known update against a possibly-stale wrapper.
if curl -fsSL "https://github.com/${RUNNERS_REPO}/archive/${RUNNERS_REF}.tar.gz" \
    | tar -xz -C "$RUNNERS_TMP" --strip-components=1 2>/dev/null \
    && [ -r "$RUNNERS_TMP/base/lib-refresh.sh" ]; then
  export AGENT_USER AGENT_HOME
  # shellcheck source=/dev/null
  . "$RUNNERS_TMP/base/lib.sh"
  # shellcheck source=/dev/null
  . "$RUNNERS_TMP/base/lib-refresh.sh"

  # 1. SideButton CLI/server npm package (server agents only; serverless = no-op).
  sb_refresh_server_cli

  # 2. agent-runners base artifacts (+ 3. catalog ops pack, reconciled inside).
  sb_refresh_base_artifacts "$RUNNERS_TMP/base" "$RUNNERS_REF" \
    || echo "sb-self-update: WARN base-artifact refresh reported an error (see ${LOG_FILE})"
else
  echo "sb-self-update: WARN could not fetch ${RUNNERS_REPO}@${RUNNERS_REF} — CLI upgrade + base artifacts not applied"
fi
