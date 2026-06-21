# 20-mark-installed.sh — write the idempotency marker and final summary.

# Record the base-artifacts fingerprint (+ the source repo) at provision so the
# portal can detect base-script drift even before the first sb-self-update refresh
# writes /etc/sidebutton/updated — i.e. agents provisioned long ago that the repo
# has since moved past (SCRUM-1380). sb_base_artifacts_fingerprint is the same
# hash sb-self-update gates on, so provision and refresh report comparably.
# shellcheck source=./lib-refresh.sh
. "$BASE_DIR/lib-refresh.sh"
BASE_ARTIFACTS_SHA="$(sb_base_artifacts_fingerprint "$BASE_DIR" 2>/dev/null || echo unknown)"

mkdir -p "$(dirname "$INSTALL_MARKER")"
{
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "agent_name=${AGENT_NAME}"
  echo "agent_role=${AGENT_ROLE}"
  echo "agent_runner=${AGENT_RUNNER:-unknown}"
  echo "runners_ref=${RUNNERS_REF:-unknown}"
  echo "runners_repo=${RUNNERS_REPO:-sidebutton/agent-runners}"
  echo "base_artifacts_sha=${BASE_ARTIFACTS_SHA:-unknown}"
  echo "bootstrap_version=${BOOTSTRAP_VERSION:-unknown}"
} > "$INSTALL_MARKER"

log ""
log "═══ SideButton agent install complete ═══"
log "  agent:      ${AGENT_NAME} (role: ${AGENT_ROLE})"
log "  runner:     ${AGENT_RUNNER:-unknown} @ ${RUNNERS_REF:-unknown}"
log "  portal:     ${PORTAL_URL}"
log "  rdp:        ${AGENT_USER}@<vm-ip>:3389  (password stored in ${ENV_FILE})"
log "  health:     curl -s http://localhost:9876/health"
log "  log:        ${LOG_FILE}"
log ""
log "NEXT (operator):"
log "  1. If secrets were not auto-populated, fill in ${ENV_FILE}: ANTHROPIC_API_KEY, GH_TOKEN, GIT_USER_*, JIRA_*"
log "  2. Verify: systemctl status sidebutton && curl -s http://localhost:9876/health"
