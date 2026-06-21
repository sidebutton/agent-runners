#!/usr/bin/env bash
# base/lib-refresh.sh — shared, change-gated base-artifact refresh (SCRUM-1380).
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
