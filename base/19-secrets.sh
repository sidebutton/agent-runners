# 19-secrets.sh — pull per-agent secrets (ANTHROPIC_API_KEY, GH_TOKEN, JIRA_*,
# RDP password) using the sb_token returned by the heartbeat.

if [ -n "${SB_TOKEN:-}" ]; then
  log "Fetching agent secrets from portal..."
  SECRETS_RESP="$(mktemp)"
  SECRETS_CODE=$(curl -4 -sS -o "$SECRETS_RESP" -w '%{http_code}' \
    -X GET "${PORTAL_URL}/api/agents/secrets" \
    -H "Authorization: Bearer ${SB_TOKEN}" \
    --connect-timeout 10 --max-time 30 || echo "000")

  log "secrets: HTTP ${SECRETS_CODE}"
  if [ "$SECRETS_CODE" = "200" ]; then
    # The portal secrets endpoint returns { agent_env: {...}, rdp_password }: the
    # account/assistant env vars live under .agent_env, NOT .env (SCRUM-1196). No
    # 2>/dev/null on the keys filter, so a future response-shape change is loud
    # instead of silently writing zero env vars.
    ENV_KEYS=$(jq -r '.agent_env | keys[]' "$SECRETS_RESP" || echo "")
    for key in $ENV_KEYS; do
      val=$(jq -r --arg k "$key" '.agent_env[$k]' "$SECRETS_RESP" 2>/dev/null || echo "")
      # KEY=VALUE with no 'export' so sidebutton.service's systemd
      # EnvironmentFile actually reads these (GH_TOKEN, ANTHROPIC_*, …) — see base/12.
      if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
      else
        echo "${key}=\"${val}\"" >> "$ENV_FILE"
      fi
    done

    RDP_PASS=$(jq -r '.rdp_password // empty' "$SECRETS_RESP" 2>/dev/null || echo "")
    if [ -n "$RDP_PASS" ]; then
      echo "${AGENT_USER}:${RDP_PASS}" | chpasswd
      log "RDP password applied for ${AGENT_USER}"
    fi

    chmod 600 "$ENV_FILE"
    chown "${AGENT_USER}:${AGENT_USER}" "$ENV_FILE"
    if [ -n "$ENV_KEYS" ]; then
      log "Secrets written to ${ENV_FILE}"
    else
      log "WARN: no agent_env keys in secrets response — ${ENV_FILE} has no account env (only rdp_password applied)"
    fi

    # AAP-C (SCRUM-1506): stage each NATIVE agent-app's per-app env under ${ENV_FILE}.d/<slug>, keyed by
    # the app's non-secret slug. The response carries these as
    #   .agent_app_env: { "<slug>": { "ANTHROPIC_API_KEY": "…", … }, … }
    # The ops workflow selects one at launch by slug: it `source`s ~/.agent-env.d/<slug> for a native-
    # provider run, or (no file) clears the provider vars for a subscription run — de-fanging the "brick".
    # Lines are `export KEY="VALUE"` (NOT the bare KEY=VALUE of the systemd EnvironmentFile ${ENV_FILE})
    # because this file is `source`d by the launch shell, so the values must be exported to reach the
    # `claude` child. Only native apps appear (subscription resolves to {} → omitted → no file → the
    # YAML's unset branch). A missing .agent_app_env key = older portal → no-op (back-compat). No
    # 2>/dev/null on the slug filter so a response-shape change is loud, not a silent skip (SCRUM-1196).
    APP_ENV_DIR="${ENV_FILE}.d"
    APP_SLUGS=$(jq -r '.agent_app_env // {} | keys[]' "$SECRETS_RESP" || echo "")
    if [ -n "$APP_SLUGS" ]; then
      mkdir -p "$APP_ENV_DIR"
      chmod 700 "$APP_ENV_DIR"
      staged=0
      for slug in $APP_SLUGS; do
        APP_KEYS=$(jq -r --arg s "$slug" '.agent_app_env[$s] | keys[]' "$SECRETS_RESP" 2>/dev/null || echo "")
        # Never stage an empty file — an empty `.d/<slug>` would be `-f` true yet skip the unset branch,
        # letting a stray provider var leak into that run. The portal only emits non-empty entries anyway.
        [ -n "$APP_KEYS" ] || continue
        APP_FILE="${APP_ENV_DIR}/${slug}"
        ( umask 177; : > "$APP_FILE" )   # create 0600 BEFORE any secret lands
        for key in $APP_KEYS; do
          val=$(jq -r --arg s "$slug" --arg k "$key" '.agent_app_env[$s][$k]' "$SECRETS_RESP" 2>/dev/null || echo "")
          echo "export ${key}=\"${val}\"" >> "$APP_FILE"
        done
        chmod 600 "$APP_FILE"
        staged=$((staged + 1))
      done
      chown -R "${AGENT_USER}:${AGENT_USER}" "$APP_ENV_DIR" 2>/dev/null || true
      log "Per-app env staged: ${staged} app(s) under ${APP_ENV_DIR}"
    fi
  elif [ "$SECRETS_CODE" = "404" ]; then
    log "INFO: no secrets row for this agent (legacy/unregistered) — skipping"
  else
    log "WARN: secrets fetch failed with HTTP ${SECRETS_CODE} — fill ${ENV_FILE} manually"
  fi
  rm -f "$SECRETS_RESP"
else
  log "INFO: no sb_token from heartbeat — secrets fetch skipped (heartbeat may have failed)"
fi
