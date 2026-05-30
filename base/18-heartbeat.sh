# 18-heartbeat.sh — register with the portal. Records sb_token + DNS hostname
# in .agent-env on success. Aborts the install only on a definitive 401 (bad
# bootstrap token) — other failures are logged and tolerated so the install
# still produces a usable VM.

step "Heartbeat: registering with ${PORTAL_URL}"
HEARTBEAT_BODY=$(jq -n \
  --arg node "$(node --version 2>/dev/null || echo unknown)" \
  --arg chrome "$(google-chrome-stable --version 2>/dev/null | awk '{print $3}')" \
  --arg sb "$(sidebutton --version 2>/dev/null || echo unknown)" \
  --arg claude "$(claude --version 2>/dev/null || echo unknown)" \
  --arg installer "${BOOTSTRAP_VERSION:-unknown}" \
  --arg runner "${AGENT_RUNNER:-unknown}" \
  --arg runners_ref "${RUNNERS_REF:-unknown}" \
  '{dependency_versions: {node:$node, chrome:$chrome, sidebutton:$sb, claude_code:$claude, installer:$installer, agent_runner:$runner, runners_ref:$runners_ref}}')

HEARTBEAT_RESP="$(mktemp)"
HEARTBEAT_CODE=$(curl -sS -o "$HEARTBEAT_RESP" -w '%{http_code}' \
  -X POST "${PORTAL_URL}/api/agents/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_TOKEN}" \
  -H "X-Agent-Name: ${AGENT_NAME}" \
  -d "$HEARTBEAT_BODY" \
  --connect-timeout 10 --max-time 30 || echo "000")

log "heartbeat: HTTP ${HEARTBEAT_CODE}"
if [ "$HEARTBEAT_CODE" = "401" ]; then
  log "ERROR: heartbeat returned 401 Unauthorized."
  log "  → AGENT_TOKEN is invalid, expired, or revoked."
  log "  → Generate a fresh bootstrap token at ${PORTAL_URL}/portal/agents and re-run with:"
  log "      sudo AGENT_TOKEN=<new> AGENT_NAME=${AGENT_NAME} bash install.sh"
  die "abort: invalid bootstrap token"
fi

SB_TOKEN=""
if [ "$HEARTBEAT_CODE" -lt 200 ] || [ "$HEARTBEAT_CODE" -ge 300 ]; then
  log "WARN: heartbeat failed with HTTP ${HEARTBEAT_CODE} — recording marker anyway; portal may be unreachable"
else
  AGENT_DNS=$(jq -r '.dns // empty' "$HEARTBEAT_RESP" 2>/dev/null || echo "")
  AGENT_IP=$(jq -r '.ip // empty' "$HEARTBEAT_RESP" 2>/dev/null || echo "")
  SB_TOKEN=$(jq -r '.sb_token // empty' "$HEARTBEAT_RESP" 2>/dev/null || echo "")
  if [ -n "$AGENT_DNS" ]; then
    sed -i "s|^export AGENT_DNS=.*|export AGENT_DNS=\"${AGENT_DNS}\"|" "$ENV_FILE"
    log "registered: ip=${AGENT_IP} dns=${AGENT_DNS}"
  fi
  if [ -n "$SB_TOKEN" ]; then
    sed -i "s|^export AGENT_TOKEN=.*|export AGENT_TOKEN=\"${SB_TOKEN}\"|" "$ENV_FILE"
    log "sb_token persisted to ${ENV_FILE}"
  fi
fi
rm -f "$HEARTBEAT_RESP"
export SB_TOKEN
