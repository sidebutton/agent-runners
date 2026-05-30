#!/usr/bin/env bash
# base/lib.sh — shared helpers for the install step scripts.
# Sourced once by base/run.sh; constants and functions are available to all
# subsequent step files.

LOG_FILE="${LOG_FILE:-/var/log/sidebutton-install.log}"
INSTALL_MARKER="${INSTALL_MARKER:-/etc/sidebutton/installed}"
AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/${AGENT_USER}}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

step() {
  log ""
  log "──── $* ────"
}

run_variant_hook() {
  local hook="$1"
  local hook_file="${RUNNERS_VARIANT_DIR:-}/${hook}.sh"
  if [ -n "${RUNNERS_VARIANT_DIR:-}" ] && [ -f "$hook_file" ]; then
    step "Variant hook: ${AGENT_RUNNER:-unknown}/${hook}"
    # shellcheck disable=SC1090
    . "$hook_file"
  fi
}
