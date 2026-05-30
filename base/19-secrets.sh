# 19-secrets.sh — pull per-agent secrets (ANTHROPIC_API_KEY, GH_TOKEN, JIRA_*,
# RDP password) using the sb_token returned by the heartbeat.

if [ -n "${SB_TOKEN:-}" ]; then
  log "Fetching agent secrets from portal..."
  SECRETS_RESP="$(mktemp)"
  SECRETS_CODE=$(curl -sS -o "$SECRETS_RESP" -w '%{http_code}' \
    -X GET "${PORTAL_URL}/api/agents/secrets" \
    -H "Authorization: Bearer ${SB_TOKEN}" \
    --connect-timeout 10 --max-time 30 || echo "000")

  log "secrets: HTTP ${SECRETS_CODE}"
  if [ "$SECRETS_CODE" = "200" ]; then
    ENV_KEYS=$(jq -r '.env | keys[]' "$SECRETS_RESP" 2>/dev/null || echo "")
    for key in $ENV_KEYS; do
      val=$(jq -r --arg k "$key" '.env[$k]' "$SECRETS_RESP" 2>/dev/null || echo "")
      if grep -q "^export ${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^export ${key}=.*|export ${key}=\"${val}\"|" "$ENV_FILE"
      else
        echo "export ${key}=\"${val}\"" >> "$ENV_FILE"
      fi
    done

    RDP_PASS=$(jq -r '.rdp_password // empty' "$SECRETS_RESP" 2>/dev/null || echo "")
    if [ -n "$RDP_PASS" ]; then
      echo "${AGENT_USER}:${RDP_PASS}" | chpasswd
      log "RDP password applied for ${AGENT_USER}"
    fi

    chmod 600 "$ENV_FILE"
    chown "${AGENT_USER}:${AGENT_USER}" "$ENV_FILE"
    log "Secrets written to ${ENV_FILE}"
  elif [ "$SECRETS_CODE" = "404" ]; then
    log "INFO: no secrets row for this agent (legacy/unregistered) — skipping"
  else
    log "WARN: secrets fetch failed with HTTP ${SECRETS_CODE} — fill ${ENV_FILE} manually"
  fi
  rm -f "$SECRETS_RESP"
else
  log "INFO: no sb_token from heartbeat — secrets fetch skipped (heartbeat may have failed)"
fi
