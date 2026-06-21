# 18b-heartbeat-timer.sh — recurring base heartbeat so the portal shows the
# agent online without the SideButton server.
#
# The install-time heartbeat (base/18) registers the agent + swaps in the
# permanent sb_token, but recurring "online" otherwise relies on the portal
# polling the SB server on :9876. A serverless (manual/RDP) agent has no :9876,
# so it would drop offline after install. This timer POSTs a minimal heartbeat
# (POST /api/agents/heartbeat) on a schedule using the agent's own sb_token.
#
# Only installed when the SB server is absent — server agents already keep
# last_seen fresh via the portal's :9876 poll + the sb-health reporter (19c),
# and a second push would clobber the richer dependency_versions they report.

if [ "${SKIP_SIDEBUTTON_SERVER:-}" != "1" ]; then
  step "Step 18b: recurring heartbeat timer (skipped — SB server present)"
else
  step "Step 18b: recurring heartbeat timer (serverless online signal)"

  cat > /opt/sb-heartbeat.sh <<'EOF'
#!/usr/bin/env bash
# Minimal recurring heartbeat — refreshes the portal's last_seen for serverless agents.
set -uo pipefail
[ -f "$HOME/.agent-env" ] && . "$HOME/.agent-env"
TOK="${SIDEBUTTON_AGENT_TOKEN:-${AGENT_TOKEN:-}}"
NAME="${SIDEBUTTON_AGENT_NAME:-${AGENT_NAME:-}}"
URL="${PORTAL_URL:-https://sidebutton.com}"
[ -n "$TOK" ] && [ -n "$NAME" ] || exit 0
# Effective base-artifacts ref + fingerprint so serverless agents also report
# base-script drift (SCRUM-1380): prefer the post-refresh marker, else the
# provision marker. Both markers are root-written world-readable (0644).
REF="$(sed -n 's/^runners_ref=//p' /etc/sidebutton/updated 2>/dev/null | tail -1)"
[ -n "$REF" ] || REF="$(sed -n 's/^runners_ref=//p' /etc/sidebutton/installed 2>/dev/null | tail -1)"
[ -n "$REF" ] || REF="unknown"
BSHA="$(sed -n 's/^base_artifacts_sha=//p' /etc/sidebutton/updated 2>/dev/null | tail -1)"
[ -n "$BSHA" ] || BSHA="$(sed -n 's/^base_artifacts_sha=//p' /etc/sidebutton/installed 2>/dev/null | tail -1)"
[ -n "$BSHA" ] || BSHA="unknown"
BODY=$(jq -n \
  --arg node "$(node --version 2>/dev/null || echo unknown)" \
  --arg chrome "$(google-chrome-stable --version 2>/dev/null | awk '{print $3}')" \
  --arg sb "not-installed" \
  --arg claude "$(claude --version 2>/dev/null || echo unknown)" \
  --arg runners_ref "$REF" \
  --arg base_artifacts_sha "$BSHA" \
  '{dependency_versions:{node:$node, chrome:$chrome, sidebutton:$sb, claude_code:$claude, runners_ref:$runners_ref, base_artifacts_sha:$base_artifacts_sha}}' 2>/dev/null || echo '{}')
curl -4 -sf -X POST "${URL}/api/agents/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOK}" \
  -H "X-Agent-Name: ${NAME}" \
  -d "$BODY" --connect-timeout 10 --max-time 20 >/dev/null 2>&1 || true
EOF
  chmod 0755 /opt/sb-heartbeat.sh

  cat > /etc/systemd/system/sb-heartbeat.service <<'EOF'
[Unit]
Description=SideButton agent heartbeat (keep online)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=agent
EnvironmentFile=/home/agent/.agent-env
ExecStart=/opt/sb-heartbeat.sh
EOF

  cat > /etc/systemd/system/sb-heartbeat.timer <<'EOF'
[Unit]
Description=Run the SideButton heartbeat at boot and every 3 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now sb-heartbeat.timer >/dev/null 2>&1 \
    || log "WARN: failed to enable sb-heartbeat.timer"
  log "sb-heartbeat timer enabled (boot+1min, then every 3min)"
fi
