# components/claude-code-router/install.sh — Claude Code Router (CCR) proxy.
#
# Sourced by base/run.sh when `claude-code-router` is in AGENT_COMPONENTS. Runs as
# root at provision time, AFTER 09 (the agent user exists — this writes + chowns
# ~/.claude-code-router) and BEFORE 11/12; requires the `claude-code` component
# (enforced in base/components.sh). Installs the pinned CCR npm package, writes a
# config + the ccr.service unit, and ENABLES (does NOT start) it — the first start
# is deferred to post-services.sh, after 19-secrets has populated ~/.agent-env.
#
# ── Env contract (this component OWNS the variable names; T6/operator DELIVER the
#    values into agents.agent_env → ~/.agent-env via 19-secrets, see docs/COMPONENTS.md):
#      ANTHROPIC_BASE_URL        Claude Code → the proxy (http://127.0.0.1:3456)
#      ANTHROPIC_AUTH_TOKEN      token Claude Code presents to CCR; reused as APIKEY
#      CCR_PROVIDER_NAME         upstream provider id (also Router.default provider)
#      CCR_PROVIDER_API_BASE_URL upstream provider base URL
#      CCR_PROVIDER_API_KEY      upstream provider key
#      CCR_PROVIDER_MODEL        upstream model id (also Router.default model)
#      CCR_CONFIG_B64            optional base64 of a whole config.json (override)
#
# Why config.json carries LITERAL $VAR placeholders: install runs BEFORE 19-secrets,
# so the routing values are not present yet. CCR's interpolateEnvVars() resolves
# them at RUNTIME from its process env (systemd EnvironmentFile=~/.agent-env), so
# the secrets are never baked into the image. Idempotent (command -v / overwrite).

step "Component: Claude Code Router (CCR)"

# Pin exact — CCR moves fast and a major can change the config schema + the
# base/14 stop-hook route reader. Bump deliberately.
CCR_VERSION="2.0.0"

# 1. Install the pinned CCR package (global → /usr/bin/ccr, same prefix as
#    /usr/bin/sidebutton). WARN-not-die: CCR is optional and Restart=always +
#    a later provision/operator retry recovers.
if command -v ccr >/dev/null 2>&1; then
  log "ccr already installed: $(ccr version 2>/dev/null || ccr -v 2>/dev/null || echo present)"
else
  npm install -g "@musistudio/claude-code-router@${CCR_VERSION}" >/dev/null 2>&1 \
    && log "ccr: installed @musistudio/claude-code-router@${CCR_VERSION}" \
    || log "WARN: ccr npm install failed — retry with 'npm i -g @musistudio/claude-code-router@${CCR_VERSION}'"
fi

# 2. config.json. Always lay down the env-template first (so a valid config always
#    exists for first boot); a non-empty CCR_CONFIG_B64 then atomically overrides
#    it. SINGLE-QUOTED heredoc → the $VARs land LITERAL (CCR interpolates them at
#    runtime). Shape kept compatible with base/14 detect_effective_route (T9):
#    Router.default = "provider,model" + Providers[0].{name,models[0]}.
CCR_HOME="$AGENT_HOME/.claude-code-router"
mkdir -p "$CCR_HOME/logs"

cat > "$CCR_HOME/config.json" <<'EOF'
{
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "APIKEY": "$ANTHROPIC_AUTH_TOKEN",
  "NON_INTERACTIVE_MODE": true,
  "Providers": [
    {
      "name": "$CCR_PROVIDER_NAME",
      "api_base_url": "$CCR_PROVIDER_API_BASE_URL",
      "api_key": "$CCR_PROVIDER_API_KEY",
      "models": ["$CCR_PROVIDER_MODEL"]
    }
  ],
  "Router": { "default": "$CCR_PROVIDER_NAME,$CCR_PROVIDER_MODEL" }
}
EOF
_ccr_config_src='env-template ($VAR placeholders interpolated by CCR at runtime)'

if [ -n "${CCR_CONFIG_B64:-}" ]; then
  if printf '%s' "$CCR_CONFIG_B64" | base64 -d > "$CCR_HOME/config.json.tmp" 2>/dev/null \
     && [ -s "$CCR_HOME/config.json.tmp" ]; then
    mv "$CCR_HOME/config.json.tmp" "$CCR_HOME/config.json"
    _ccr_config_src='CCR_CONFIG_B64 override'
  else
    rm -f "$CCR_HOME/config.json.tmp"
    log "WARN: CCR_CONFIG_B64 set but did not decode to a non-empty config — keeping the env-template"
  fi
fi

chown -R "${AGENT_USER}:${AGENT_USER}" "$CCR_HOME"
chmod 600 "$CCR_HOME/config.json"
log "ccr: config.json written (${_ccr_config_src})"

# 3. ccr.service — modeled on sidebutton.service (16-services-prep.sh). User=agent,
#    EnvironmentFile=~/.agent-env (CCR reads CCR_*/ANTHROPIC_* from it at start),
#    Restart=always. ENABLE only — first start is post-services (after 19-secrets),
#    so it boots once with a complete env (mirrors sidebutton.service's 17→19b split).
cat > /etc/systemd/system/ccr.service <<'EOF'
[Unit]
Description=Claude Code Router (CCR) proxy on 127.0.0.1:3456
After=network.target

[Service]
Type=simple
User=agent
EnvironmentFile=/home/agent/.agent-env
Environment=HOME=/home/agent
ExecStart=/usr/bin/ccr start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable ccr.service >/dev/null 2>&1 \
  && log "ccr.service enabled (not started — first start is in post-services, after 19-secrets)" \
  || log "WARN: could not enable ccr.service"

# 4. logrotate for CCR's logs (new idiom — first logrotate drop in base). copytruncate
#    so the long-lived ccr process keeps its open fd; su agent agent since the logs
#    are agent-owned under ~/.
cat > /etc/logrotate.d/claude-code-router <<'EOF'
/home/agent/.claude-code-router/logs/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su agent agent
}
EOF

log "ccr: $(command -v ccr >/dev/null 2>&1 && echo installed || echo not-installed); config + ccr.service written (enabled, started in post-services)"
