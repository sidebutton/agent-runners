# 20-mark-installed.sh — write the idempotency marker and final summary.

mkdir -p "$(dirname "$INSTALL_MARKER")"
{
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "agent_name=${AGENT_NAME}"
  echo "agent_role=${AGENT_ROLE}"
  echo "agent_runner=${AGENT_RUNNER:-unknown}"
  echo "runners_ref=${RUNNERS_REF:-unknown}"
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
