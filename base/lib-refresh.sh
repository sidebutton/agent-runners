#!/usr/bin/env bash
# base/lib-refresh.sh — shared, change-gated refresh of a live agent's deployed
# artifacts: the agent-runners BASE ARTIFACTS (SCRUM-1380) AND the universal
# "agents" CATALOG OPS PACK (the default ops workflows — companion to SCRUM-1380,
# closing the knowledge-pack half of the same fleet-drift story).
#
# Single source of truth for "re-apply the idempotent base artifacts on a live
# agent" so the fleet self-service path and the operator break-glass path can
# never drift:
#   - base/assets/sb-self-update.sh  (root wrapper, run fleet-wide by the
#     agent_pull_repos ops job via `sudo sb-self-update`)
#   - the-assistant agent-redeploy.sh §4/§4b  (operator manual-SSH break-glass)
# Both download agent-runners@<ref> to a tmp tree, then source THIS file from that
# tree and call sb_refresh_base_artifacts "<tree>/base" "<ref>".
#
# Design (maps to SCRUM-1380 items 1-3):
#   - Manifest-driven (base/refresh-manifest.txt), not a hard-coded step list, so
#     newly added refresh-safe steps reach the fleet without editing two callers.
#   - Change-gated by a fingerprint over the deployed artifacts vs the marker
#     (/etc/sidebutton/updated): a routine pull_repos tick where nothing upstream
#     changed is a true no-op — no rewrite, no service bounce.
#   - Runs as root but writes agent-owned files, so it chowns artifacts back to
#     ${AGENT_USER} (the wrapper historically only touched root-owned npm state).
#
# Expects lib.sh already sourced for log()/AGENT_USER/AGENT_HOME; falls back to a
# minimal log() and sane defaults so the file is unit-testable on its own.

command -v log >/dev/null 2>&1 || log() { printf '[lib-refresh] %s\n' "$*" >&2; }

SB_UPDATED_MARKER="${SB_UPDATED_MARKER:-/etc/sidebutton/updated}"
SB_SELF_UPDATE_BIN="${SB_SELF_UPDATE_BIN:-/usr/local/bin/sb-self-update}"

# sb_refresh_manifest_files <base_dir> — echo the manifest step filenames in order,
# stripping blank lines and whole-line / trailing `#` comments.
sb_refresh_manifest_files() {
  local mf="$1/refresh-manifest.txt"
  [ -r "$mf" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$mf" | awk 'NF'
}

# sb_base_artifacts_fingerprint <base_dir> — stable sha256 over everything that
# determines what gets deployed: the manifest steps, the hooks asset, the wrapper
# asset, this lib, and the manifest itself. Same ref + unchanged tree => same
# fingerprint on every box, so the change-gate is deterministic. A change to ANY
# of these (incl. the wrapper or a newly listed step) flips the fingerprint and
# triggers a refresh.
sb_base_artifacts_fingerprint() {
  local base="$1" f
  {
    while IFS= read -r f; do
      [ -f "$base/$f" ] && cat "$base/$f"
    done < <(sb_refresh_manifest_files "$base")
    for f in assets/claude-hooks.json assets/sb-self-update.sh lib-refresh.sh refresh-manifest.txt; do
      [ -f "$base/$f" ] && cat "$base/$f"
    done
  } 2>/dev/null | sha256sum | awk '{print $1}'
}

# sb_artifacts_current <fp_new> <ref_new> [marker] — true (0) when the marker
# already records this exact fingerprint AND ref, i.e. nothing to do.
sb_artifacts_current() {
  local fp_new="$1" ref_new="$2" marker="${3:-$SB_UPDATED_MARKER}"
  [ -r "$marker" ] || return 1
  local fp_old ref_old
  fp_old=$(sed -n 's/^base_artifacts_sha=//p' "$marker" | tail -1)
  ref_old=$(sed -n 's/^runners_ref=//p' "$marker" | tail -1)
  [ -n "$fp_old" ] && [ "$fp_old" = "$fp_new" ] && [ "$ref_old" = "$ref_new" ]
}

# _sb_merge_claude_hooks <hooks_asset> — re-merge the canonical hooks block over
# the live ~/.claude/settings.json, preserving every other key (mcpServers,
# onboarding, env). Echoes a status word; chowns the result back to the agent.
_sb_merge_claude_hooks() {
  local hooks_asset="$1"
  local settings="${AGENT_HOME:-/home/agent}/.claude/settings.json"
  if ! command -v jq >/dev/null 2>&1; then echo "skipped (no jq)"; return 0; fi
  if [ ! -f "$hooks_asset" ]; then echo "no asset"; return 0; fi
  if [ ! -f "$settings" ]; then echo "no settings.json"; return 0; fi
  local before after
  before=$(sha256sum "$settings" | awk '{print $1}')
  if jq --slurpfile h "$hooks_asset" '.hooks = $h[0].hooks' "$settings" > "${settings}.tmp" 2>/dev/null \
      && [ -s "${settings}.tmp" ] && jq -e '.hooks' "${settings}.tmp" >/dev/null 2>&1; then
    mv "${settings}.tmp" "$settings"
    chown "${AGENT_USER:-agent}:${AGENT_USER:-agent}" "$settings" 2>/dev/null || true
    after=$(sha256sum "$settings" | awk '{print $1}')
    [ "$before" = "$after" ] && echo "unchanged" || echo "updated"
  else
    rm -f "${settings}.tmp"
    echo "failed"
  fi
}

# _sb_reinstall_wrapper <base_dir> — keep /usr/local/bin/sb-self-update current
# from the fetched tree so wrapper fixes propagate via the fleet path itself.
# Best-effort + validated (non-empty, has a shebang) so a bad fetch can't brick
# the one privileged action.
_sb_reinstall_wrapper() {
  local src="$1/assets/sb-self-update.sh"
  [ -f "$src" ] || return 0
  head -1 "$src" | grep -q '^#!' || { log "wrapper asset has no shebang — not reinstalling"; return 0; }
  if [ -f "$SB_SELF_UPDATE_BIN" ] && cmp -s "$src" "$SB_SELF_UPDATE_BIN"; then
    return 0
  fi
  if install -m 0755 "$src" "$SB_SELF_UPDATE_BIN" 2>/dev/null; then
    log "sb-self-update wrapper reinstalled from ${1}"
  else
    log "WARN: could not reinstall sb-self-update wrapper"
  fi
}

# _sb_run_as_agent <user> <cmd> — run <cmd> as the agent user. In the prod wrapper
# context we are root, so drop to the agent user (the pack lives under its HOME);
# in tests / already-agent contexts run it directly so it needs no tty/su.
_sb_run_as_agent() {
  local user="$1" cmd="$2"
  if [ "$(id -u)" -eq 0 ] && [ "$(id -un)" != "$user" ]; then
    su - "$user" -c "$cmd"
  else
    eval "$cmd"
  fi
}

# sb_refresh_knowledge_packs [pack] — reconcile the universal "agents" catalog ops
# pack (the default ops workflows: agent_pull_repos, agent_se_*, agent_qa_*, …) so
# workflows added or changed after this agent was provisioned actually reach it.
#
# WHY this is SEPARATE from the base-artifact refresh and NOT a manifest step: the
# default workflows live in the sidebutton-skill-packs CATALOG, not in agent-runners,
# so they move on a different cadence and must not be gated on the agent-runners
# fingerprint. They reach an agent ONLY via `sidebutton install` against the public
# catalog; nothing else refreshes them — `sidebutton registry update` pulls only git
# REGISTRIES (base/19d), and the base-artifact manifest deliberately excludes the
# one-time provisioning step that installs this pack (base/13). Left unaddressed, a
# newly published default workflow 404s ("Workflow not found") on every already-
# provisioned agent when the orchestrator dispatches it by id.
#
# CHANGE-GATE = the CLI's own version compare (installSkillPack), so we need no
# version math here and an unchanged catalog rewrites nothing:
#   - same version already installed  -> plain install is a no-op (exit 0, "skipped")
#   - catalog moved to a new version  -> plain install refuses    (exit 1, "Use --force")
#   - not installed at all            -> plain install would install it — but the
#                                        refresh-only gate below skips this case first
# A plain install, then --force only on its failure, converges to the catalog version
# while staying a TRUE no-op when nothing changed (one cheap catalog GET, no rewrite).
#
# REFRESH-ONLY: reconciles a pack this agent ALREADY has; it never fresh-installs one
# the agent was provisioned without — components.sh allows a sidebutton-server agent
# with knowledge-packs OFF (SKIP_KNOWLEDGE_PACKS=1 ⇒ base/13 skipped), and that
# choice must be respected even though the CLI is present.
#
# Best-effort: never aborts the caller (always returns 0); a catalog-unreachable tick
# just logs and is retried on the next pull_repos. Gated off on serverless boxes (no
# `sidebutton` CLI) and by SKIP_KNOWLEDGE_PACKS=1 (parity with base/13; also the test
# kill-switch). Detail goes to log() (stderr/logfile); a one-line status is echoed to
# stdout only when it actually acts, so it surfaces in the pull_repos report.
sb_refresh_knowledge_packs() {
  local pack="${1:-agents}"
  local user="${AGENT_USER:-agent}"
  local home="${AGENT_HOME:-/home/${user}}"

  if [ "${SKIP_KNOWLEDGE_PACKS:-}" = "1" ]; then
    log "knowledge packs: skipped (SKIP_KNOWLEDGE_PACKS=1)"
    return 0
  fi
  if ! command -v sidebutton >/dev/null 2>&1; then
    log "knowledge packs: sidebutton CLI absent (serverless) — skipped"
    return 0
  fi
  # Refresh only what is already installed (CLI getConfigDir = ~/.sidebutton, packs
  # under skills/<domain>) — never fresh-install onto a deliberately packs-less agent.
  if [ ! -d "${home}/.sidebutton/skills/${pack}" ]; then
    log "knowledge packs: '${pack}' not installed on this agent — skipped (not fresh-installing)"
    return 0
  fi

  # Plain install first: exit 0 when already current, non-zero when a DIFFERENT
  # version is installed (the CLI's "Use --force" refusal).
  if _sb_run_as_agent "$user" "sidebutton install ${pack}" >/dev/null 2>&1; then
    log "knowledge packs: '${pack}' already at catalog version (no change)"
    echo "knowledge packs: ${pack} current"
    return 0
  fi

  # Non-zero — most commonly catalog drift; converge by forcing. (A genuine error,
  # e.g. the catalog unreachable, also lands here; the forced retry then fails too
  # and we log it without aborting the rest of the refresh.)
  if _sb_run_as_agent "$user" "sidebutton install ${pack} --force" >/dev/null 2>&1; then
    log "knowledge packs: '${pack}' refreshed to catalog version (--force)"
    echo "knowledge packs: ${pack} refreshed"
  else
    log "WARN: knowledge packs: '${pack}' refresh failed (catalog unreachable?) — retry next pull_repos"
    echo "knowledge packs: ${pack} refresh FAILED"
  fi
  return 0
}

# sb_refresh_base_artifacts <base_dir> <runners_ref> — the change-gated apply.
# Returns 0 on success or no-op; 1 only on an unusable tree. Individual step
# failures are logged (status=partial) but never abort, matching the break-glass
# tool's tolerance.
sb_refresh_base_artifacts() {
  local base="$1" ref="${2:-unknown}"
  if [ ! -r "$base/refresh-manifest.txt" ]; then
    log "ERROR: no refresh-manifest.txt under ${base} — base artifacts not refreshed"
    return 1
  fi

  # Catalog ops pack — reconciled on EVERY call, BEFORE (and independent of) the
  # base-artifact change-gate below: the default workflows live in the skill-packs
  # catalog and move on their own cadence, and an agent still on a pre-this wrapper
  # only ever calls THIS function, so doing it here makes a catalog bump land on the
  # same pull_repos pass. It self-gates (CLI version compare), so this is a no-op
  # when the pack is already current.
  sb_refresh_knowledge_packs

  local fp; fp=$(sb_base_artifacts_fingerprint "$base")
  if sb_artifacts_current "$fp" "$ref"; then
    log "base artifacts already current (ref=${ref} sha=${fp:0:12}) — no refresh"
    echo "base artifacts: already current (${fp:0:12})"
    return 0
  fi
  log "refreshing base artifacts (ref=${ref} sha=${fp:0:12})"

  # Component gates: a refresh on a serverless / no-packs box must not try to
  # install the SB-server-only or registry-only artifacts. Mirror the gate the
  # break-glass tool uses — tie both to whether the SB server unit exists.
  local have_sb=0
  systemctl list-unit-files sidebutton.service --no-legend >/dev/null 2>&1 \
    && [ -n "$(systemctl list-unit-files sidebutton.service --no-legend 2>/dev/null)" ] && have_sb=1

  # Keep the wrapper itself current (it is part of the fingerprint).
  _sb_reinstall_wrapper "$base"

  local status="synced" step_file
  while IFS= read -r step_file; do
    [ -f "$base/$step_file" ] || { log "WARN: manifest step ${step_file} missing in tree — skipped"; status="partial"; continue; }
    if (
      set -euo pipefail
      export AGENT_USER="${AGENT_USER:-agent}" AGENT_HOME="${AGENT_HOME:-/home/agent}"
      export BASE_DIR="$base"
      if [ "$have_sb" -ne 1 ]; then
        export SKIP_SIDEBUTTON_SERVER=1 SKIP_KNOWLEDGE_PACKS=1
      fi
      set -a
      [ -f "${AGENT_HOME:-/home/agent}/.agent-env" ] && . "${AGENT_HOME:-/home/agent}/.agent-env"
      set +a
      . "$base/lib.sh"
      . "$base/$step_file"
    ) >/dev/null 2>&1; then
      log "ok:   ${step_file}"
    else
      log "WARN: ${step_file} failed (see ${LOG_FILE:-log})"
      status="partial"
    fi
  done < <(sb_refresh_manifest_files "$base")

  local hooks_status; hooks_status=$(_sb_merge_claude_hooks "$base/assets/claude-hooks.json")
  log "claude hooks: ${hooks_status}"

  # Root wrote agent-owned artifacts (~/.local/bin scripts from step 14); hand
  # them back. settings.json is already chowned in the merge above.
  chown -R "${AGENT_USER:-agent}:${AGENT_USER:-agent}" "${AGENT_HOME:-/home/agent}/.local/bin" 2>/dev/null || true

  mkdir -p "$(dirname "$SB_UPDATED_MARKER")"
  {
    echo "updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runners_ref=${ref}"
    echo "base_artifacts_sha=${fp}"
  } > "$SB_UPDATED_MARKER"

  log "base artifacts refreshed (ref=${ref} sha=${fp:0:12} steps=${status} hooks=${hooks_status})"
  echo "base artifacts: refreshed (${fp:0:12}, steps=${status}, hooks=${hooks_status})"
  return 0
}
