#!/usr/bin/env bash
# sb-self-update — the agent fleet's single self-service update path (SCRUM-1380).
# Installed to /usr/local/bin/sb-self-update by base/08 and run as root via a
# narrow NOPASSWD sudoers rule scoped to ONLY this wrapper, by the agent_pull_repos
# ops job (`sudo sb-self-update`). It is the ONE privileged action the fleet has.
#
# It does three idempotent, change-gated things:
#   1. Upgrade the global SideButton CLI/server npm package, restarting the
#      service ONLY when the version actually changed. Self-gated on
#      `command -v sidebutton`, so it is a no-op (not an install) on serverless
#      variants that ship no SB server.
#   2. Refresh the agent-runners BASE ARTIFACTS — re-run the idempotent base steps
#      (base/refresh-manifest.txt) + re-merge the Claude hooks block — from a fresh
#      download of agent-runners@<ref>, so step-script / hook changes (the gate
#      uploader, the needs-input forwarder, the session reaper, …) reach existing
#      agents without an operator SSH. Change-gated by a fingerprint vs
#      /etc/sidebutton/updated: a routine tick with nothing new upstream is a true
#      no-op. The shared apply logic lives in base/lib-refresh.sh (also used by the
#      operator break-glass agent-redeploy.sh) so the two paths can't drift.
#   3. Reconcile the universal "agents" CATALOG OPS PACK — re-pull the default ops
#      workflows from the public catalog so ones added/changed after this agent was
#      provisioned stop 404-ing on dispatch. This rides step 2 (sb_refresh_base_
#      artifacts calls sb_refresh_knowledge_packs), so an agent still on a pre-this
#      wrapper picks it up on the very next pull_repos. Change-gated by the CLI's own
#      version compare — a no-op when the pack is already current.
#
# A root sudo wrapper inherits no agent env, so it resolves the repo/ref itself
# from /etc/sidebutton/{updated,installed} and hands artifacts back to the agent.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LOG_FILE="${LOG_FILE:-/var/log/sidebutton-update.log}"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/${AGENT_USER}}"

# --- 1. SideButton CLI/server npm package (server agents only) ----------------
if command -v sidebutton >/dev/null 2>&1; then
  before="$(sidebutton --version 2>/dev/null || echo none)"
  if npm install -g sidebutton@latest >/dev/null 2>&1; then
    after="$(sidebutton --version 2>/dev/null || echo none)"
    if [ "$before" != "$after" ]; then
      systemctl restart sidebutton 2>/dev/null || true
      echo "sb-self-update: sidebutton upgraded ${before} -> ${after} (service restarted)"
    else
      echo "sb-self-update: sidebutton already at ${after} (no change)"
    fi
  else
    echo "sb-self-update: WARN npm install of sidebutton failed"
  fi
else
  echo "sb-self-update: sidebutton not installed (serverless) — skipping npm upgrade"
fi

# --- 2. agent-runners base artifacts (all agents) -----------------------------
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

if curl -fsSL "https://github.com/${RUNNERS_REPO}/archive/${RUNNERS_REF}.tar.gz" \
    | tar -xz -C "$RUNNERS_TMP" --strip-components=1 2>/dev/null \
    && [ -r "$RUNNERS_TMP/base/lib-refresh.sh" ]; then
  export AGENT_USER AGENT_HOME
  # shellcheck source=/dev/null
  . "$RUNNERS_TMP/base/lib.sh"
  # shellcheck source=/dev/null
  . "$RUNNERS_TMP/base/lib-refresh.sh"
  sb_refresh_base_artifacts "$RUNNERS_TMP/base" "$RUNNERS_REF" \
    || echo "sb-self-update: WARN base-artifact refresh reported an error (see ${LOG_FILE})"
else
  echo "sb-self-update: WARN could not fetch ${RUNNERS_REPO}@${RUNNERS_REF} — base artifacts not refreshed"
fi
