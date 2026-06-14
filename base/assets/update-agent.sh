#!/usr/bin/env bash
# update-agent.sh — roll the sidebutton npm package to the latest published version on a live agent.
#
# Usage (run as root or via sudo on the target VM):
#   curl -fsSL https://raw.githubusercontent.com/sidebutton/agent-runners/main/base/assets/update-agent.sh | bash
#   # or, after downloading the repo:
#   sudo bash ~/agent-runners/base/assets/update-agent.sh [--version <tag>]
#
# What it does:
#   1. Stops the sidebutton.service (if running).
#   2. Installs sidebutton@<version> (default: latest) globally via npm.
#   3. Restarts the sidebutton.service (if it was running before).
#   4. Verifies the /health endpoint responds on :9876.
#
# Idempotent: re-running when the target version is already installed is a no-op (npm skips).
# Safe for cron / CI — exits non-zero on any failure so callers can detect problems.
#
# SCRUM-1299: ships the packages/server T2 code (POST /api/skills/apply) to existing fleet agents
# without requiring a full re-provision. Run this after every portal release that bumps packages/server.

set -euo pipefail

VERSION="${1:-}"
# Parse --version flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TARGET="${VERSION:-latest}"
AGENT_PORT=9876
HEALTH_TIMEOUT=30  # seconds to wait for :9876/health after restart

log()  { echo "[update-agent] $*"; }
die()  { echo "[update-agent] ERROR: $*" >&2; exit 1; }

# Must run as root (or via sudo) so npm -g installs to /usr/local/lib.
if [[ "$EUID" -ne 0 ]]; then
  die "Run as root: sudo bash $0 $*"
fi

# ── 1. Determine current state ──────────────────────────────────────────────
SERVICE_ACTIVE=0
if systemctl is-active --quiet sidebutton.service 2>/dev/null; then
  SERVICE_ACTIVE=1
  log "sidebutton.service is running — will restart after update"
fi

CURRENT_VERSION=$(sidebutton --version 2>/dev/null || echo "none")
log "Current version: ${CURRENT_VERSION}  →  target: ${TARGET}"

# ── 2. Stop service ──────────────────────────────────────────────────────────
if [[ "$SERVICE_ACTIVE" -eq 1 ]]; then
  systemctl stop sidebutton.service
  log "sidebutton.service stopped"
fi

# ── 3. Install / upgrade ─────────────────────────────────────────────────────
log "Installing sidebutton@${TARGET} globally…"
npm install -g "sidebutton@${TARGET}" --prefer-online
NEW_VERSION=$(sidebutton --version 2>/dev/null || echo "unknown")
log "Installed version: ${NEW_VERSION}"

# ── 4. Restart service ───────────────────────────────────────────────────────
if [[ "$SERVICE_ACTIVE" -eq 1 ]]; then
  systemctl start sidebutton.service
  log "sidebutton.service started"
fi

# ── 5. Health check ──────────────────────────────────────────────────────────
# Only verify if the service was (and is now expected to be) running.
if [[ "$SERVICE_ACTIVE" -eq 1 ]]; then
  log "Waiting up to ${HEALTH_TIMEOUT}s for :${AGENT_PORT}/health…"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while true; do
    if curl -sf "http://localhost:${AGENT_PORT}/health" >/dev/null 2>&1; then
      log "Health check passed — /api/skills/apply is now live"
      break
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      die "sidebutton service did not respond on :${AGENT_PORT}/health within ${HEALTH_TIMEOUT}s"
    fi
    sleep 2
  done
else
  log "Service was not running before update — skipping health check"
fi

log "Done. sidebutton ${NEW_VERSION} is active."
