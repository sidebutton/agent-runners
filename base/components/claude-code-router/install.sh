# components/claude-code-router/install.sh — Claude Code Router (CCR) proxy.
#
# Sourced by base/run.sh when `claude-code-router` is in AGENT_COMPONENTS. Runs as
# root at provision time, AFTER 09 (the agent user exists — this writes + chowns
# ~/.claude-code-router) and BEFORE 11/12; requires the `claude-code` component
# (enforced in base/components.sh). Installs the pinned CCR npm package, writes a
# config + the ccr.service unit, and ENABLES (does NOT start) it — the first start
# is deferred to post-services.sh, after 19-secrets has populated ~/.agent-env.
#
# ── Routing source (SCRUM-1613 / AAP-Cb): the portal's CCR APP ROW, delivered
#    per-app into ~/.agent-env.d/<slug> and mirrored here by sb-ccr-sync:
#      ANTHROPIC_BASE_URL        Claude Code → the proxy (http://127.0.0.1:3456)
#      ANTHROPIC_AUTH_TOKEN      token Claude Code presents to CCR; reused as APIKEY
#      CCR_CONFIG_B64            base64 of the whole generated config.json
#    sb-ccr-sync derives ~/.claude-code-router/{ccr.env,config.json} from that file
#    and restarts this service when they change; ccr-env-sync.path makes a live
#    portal config-apply reach the running daemon. See docs/COMPONENTS.md.
#
#    RETIRED with it: the GLOBAL env contract (~/.agent-env carrying ANTHROPIC_* and
#    CCR_PROVIDER_*). ccr.service no longer reads ~/.agent-env at all, so operator
#    values pasted into the per-agent env editor no longer route anything — the app
#    row is the single source. The only surviving global input is a cloud-init
#    CCR_CONFIG_B64, used at first boot before any app row exists (see below).
#
# Why config.json carries LITERAL $VAR placeholders: install runs BEFORE 19-secrets,
# so the routing values are not present yet. CCR's interpolateEnvVars() resolves
# them at RUNTIME from its process env (systemd EnvironmentFile=the sidecar), so
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

# 3. sb-ccr-sync — the app-row → daemon bridge (SCRUM-1613). Installed before the
#    units below because they invoke it. Component-local install (this is the only
#    component that has a daemon to feed), same install -m 0755 idiom as base/19f.
CCR_SYNC_SRC="${BASE_DIR}/components/claude-code-router/sb-ccr-sync"
if [ -f "$CCR_SYNC_SRC" ]; then
  install -m 0755 "$CCR_SYNC_SRC" /usr/local/bin/sb-ccr-sync \
    && log "sb-ccr-sync installed" \
    || log "WARN: could not install sb-ccr-sync — CCR will not follow portal app changes"
else
  log "WARN: sb-ccr-sync asset missing ($CCR_SYNC_SRC) — CCR routing delivery disabled"
fi

# The watched dir, created now so the path unit below attaches its inotify watch at
# once rather than after 19-secrets first populates it. Same mode 19-secrets uses.
mkdir -p "$AGENT_HOME/.agent-env.d"
chmod 700 "$AGENT_HOME/.agent-env.d"
chown "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME/.agent-env.d"

# 4. ccr.service — modeled on sidebutton.service (16-services-prep.sh). User=agent,
#    Restart=always. ENABLE only — first start is post-services (after 19-secrets),
#    so it boots once with a complete env (mirrors sidebutton.service's 17→19b split).
#
#    EnvironmentFile is the DERIVED SIDECAR, not ~/.agent-env (SCRUM-1613): the
#    routing env arrives per-app in ~/.agent-env.d/<slug>, whose `export KEY="VALUE"`
#    lines systemd refuses ("Ignoring invalid environment assignment") and whose name
#    is account-defined; sb-ccr-sync mirrors it into this fixed bare-format path. The
#    leading `-` tolerates its absence — a CCR agent with no app row yet must still
#    boot the proxy (on the template config) instead of failing to start.
cat > /etc/systemd/system/ccr.service <<'EOF'
[Unit]
Description=Claude Code Router (CCR) proxy on 127.0.0.1:3456
After=network.target

[Service]
Type=simple
User=agent
EnvironmentFile=-/home/agent/.claude-code-router/ccr.env
Environment=HOME=/home/agent
ExecStart=/usr/bin/ccr start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 5. ccr-env-sync.{service,path} — F4: a portal config-apply rewrites ~/.agent-env.d/*
#    on the running agent, and this watcher turns that write into a re-derive + a
#    gated restart, so a rotated key or a changed upstream reaches the live daemon.
#
#    EDGE-TRIGGERED ONLY (PathModified). A level-triggered spec (PathExists= /
#    DirectoryNotEmpty=) is re-evaluated when the triggered unit stops, and this sync
#    deliberately never empties the dir it watches — so boot coverage comes from
#    enabling the oneshot itself (WantedBy=multi-user.target) rather than from a
#    condition that stays true. Watching the DIRECTORY (not per-slug files) is what
#    makes it slug-agnostic: inotify reports creates, deletes and in-place writes of
#    the children, which is exactly how the agent reconciler updates them.
cat > /etc/systemd/system/ccr-env-sync.service <<'EOF'
[Unit]
Description=Sync the CCR app env into ccr.service's sidecar + config.json

[Service]
Type=oneshot
# One config-apply rewrites every slug file; settle so the burst becomes one derive.
# (Any extra run is a no-op anyway — sb-ccr-sync is sha-gated.)
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/sb-ccr-sync
# Re-derive once more before exiting. A write that lands WHILE this oneshot is running is not
# guaranteed to raise a fresh trigger afterwards (systemd drops the inotify watch for the duration
# of the triggered unit and, on re-arming, explicitly does not re-fire an edge spec) — so without
# this pass, a second apply arriving inside the window above would leave the daemon on the previous
# upstream until some LATER write happened to poke the dir. Reading the files again costs a sha
# compare and changes nothing in the common case. `-` so a failure here cannot fail the unit.
ExecStartPost=-/usr/local/bin/sb-ccr-sync

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ccr-env-sync.path <<'EOF'
[Unit]
Description=Watch the per-app env dir for CCR routing changes

[Path]
PathModified=/home/agent/.agent-env.d
Unit=ccr-env-sync.service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable ccr.service >/dev/null 2>&1 \
  && log "ccr.service enabled (not started — first start is in post-services, after 19-secrets)" \
  || log "WARN: could not enable ccr.service"
# --now on the watcher only: it must be live before the first apply, and starting a
# .path unit just attaches the inotify watch (it does not run the sync).
systemctl enable --now ccr-env-sync.path >/dev/null 2>&1 \
  && log "ccr-env-sync.path watching ~/.agent-env.d (live portal applies reach the daemon)" \
  || log "WARN: could not enable ccr-env-sync.path — CCR will not follow portal app changes"
systemctl enable ccr-env-sync.service >/dev/null 2>&1 \
  || log "WARN: could not enable ccr-env-sync.service (boot-time re-derive)"

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
