# 18-heartbeat.sh — register with the portal. Records sb_token + DNS hostname
# in .agent-env on success. Aborts the install only on a definitive 401 (bad
# bootstrap token) — other failures are logged and tolerated so the install
# still produces a usable VM.

step "Heartbeat: registering with ${PORTAL_URL}"
# `sidebutton --version` is only meaningful when the SB server is installed.
# For variants that skip it (SKIP_SIDEBUTTON_SERVER=1) we report "not-installed"
# rather than "unknown" so the portal can distinguish "variant doesn't ship SB"
# from "lookup failed" (matters for type-adaptive health semantics in SCRUM-1095).
if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  SB_VERSION="not-installed"
else
  SB_VERSION="$(sidebutton --version 2>/dev/null || echo unknown)"
fi

# Runner variant + extension presence are reported at the top level so the
# portal can persist them on agents.runner and interpret browser_connected
# relative to the variant (SCRUM-1095). Only the extension overlay actually
# installs the Chrome managed-policy that loads the SideButton extension;
# every other variant is `has_extension=false` by design, and a `false`
# browser_connected on those must not be treated as an error.
AGENT_RUNNER_VAL="${AGENT_RUNNER:-sidebutton-mcp-claude-code-extension}"
case "$AGENT_RUNNER_VAL" in
  sidebutton-mcp-claude-code-extension) HAS_EXTENSION="true" ;;
  *) HAS_EXTENSION="false" ;;
esac

HEARTBEAT_BODY=$(jq -n \
  --arg node "$(node --version 2>/dev/null || echo unknown)" \
  --arg chrome "$(google-chrome-stable --version 2>/dev/null | awk '{print $3}')" \
  --arg sb "$SB_VERSION" \
  --arg claude "$(claude --version 2>/dev/null || echo unknown)" \
  --arg installer "${BOOTSTRAP_VERSION:-unknown}" \
  --arg runner "$AGENT_RUNNER_VAL" \
  --arg runners_ref "${RUNNERS_REF:-unknown}" \
  --argjson has_extension "$HAS_EXTENSION" \
  '{runner:$runner, has_extension:$has_extension, dependency_versions: {node:$node, chrome:$chrome, sidebutton:$sb, claude_code:$claude, installer:$installer, agent_runner:$runner, runners_ref:$runners_ref}}')

HEARTBEAT_RESP="$(mktemp)"
# Force IPv4 (-4): on dual-stack VMs (e.g. Hetzner) outbound may prefer IPv6, but
# the portal records only the IPv4 client IP — an IPv6-only heartbeat leaves the
# agent with no IP, so it can't be health-polled or get a DNS A record and shows
# offline minutes after install. -4 makes this first-run heartbeat register IPv4 + DNS.
HEARTBEAT_CODE=$(curl -4 -sS -o "$HEARTBEAT_RESP" -w '%{http_code}' \
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
    sed -i "s|^AGENT_DNS=.*|AGENT_DNS=\"${AGENT_DNS}\"|" "$ENV_FILE"
    log "registered: ip=${AGENT_IP} dns=${AGENT_DNS}"
  fi
  if [ -n "$SB_TOKEN" ]; then
    # Swap the single-use bootstrap token for the permanent sb_token under both
    # names the server + hooks read (no 'export' — systemd EnvironmentFile format).
    sed -i "s|^AGENT_TOKEN=.*|AGENT_TOKEN=\"${SB_TOKEN}\"|; s|^SIDEBUTTON_AGENT_TOKEN=.*|SIDEBUTTON_AGENT_TOKEN=\"${SB_TOKEN}\"|" "$ENV_FILE"
    log "sb_token persisted to ${ENV_FILE}"
  fi
fi
rm -f "$HEARTBEAT_RESP"
export SB_TOKEN
