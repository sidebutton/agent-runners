# components/claude-code-router/post-services.sh — start CCR + health-check.
#
# Sourced by base/run.sh at the post-services phase (after 19b) when
# `claude-code-router` is selected — i.e. AFTER 19-secrets has staged the portal's
# per-app env under ~/.agent-env.d/, so this is the first start of ccr.service
# (install.sh only ENABLED it). Mirrors the sidebutton-extension post-services
# pattern: best-effort, runs under run.sh's `set -euo pipefail`, so every probe must
# WARN-not-die.

step "Starting Claude Code Router (CCR) + health probe"

CCR_HOME="$AGENT_HOME/.claude-code-router"
SIDECAR="$CCR_HOME/ccr.env"

# PRIMARY (SCRUM-1613): the portal's CCR app row, staged by 19-secrets a moment ago as
# ~/.agent-env.d/<slug>. sb-ccr-sync finds it by its CCR_CONFIG_B64 marker and derives
# both artifacts the daemon consumes — the bare-format sidecar ccr.service pins as its
# EnvironmentFile, and config.json. --no-restart because the (re)start below IS this
# service's first start; the same helper restarts on its own for every later change,
# driven by ccr-env-sync.path. Never fatal: a WARN here still leaves a bootable proxy
# on the install-time template.
if [ -x /usr/local/bin/sb-ccr-sync ]; then
  /usr/local/bin/sb-ccr-sync --no-restart || log "WARN: sb-ccr-sync reported an error — see above"
else
  log "WARN: sb-ccr-sync not installed — CCR cannot consume the portal's app env"
fi

# FALLBACK: a cloud-init CCR_CONFIG_B64. It is the only routing input that can predate
# an app row (an operator provisioning a self-configured router), so it applies ONLY
# when the app-row path produced nothing — the portal row always wins. The trailing
# `|| true` on the extraction is REQUIRED: this script is sourced into run.sh's
# `set -euo pipefail` shell, so an absent key (the common case) makes grep exit 1,
# pipefail propagates it to the assignment, and set -e would abort the whole provision.
if [ ! -f "$SIDECAR" ] && [ -z "${CCR_CONFIG_B64:-}" ] && [ -f "$AGENT_HOME/.agent-env" ]; then
  CCR_CONFIG_B64="$(grep -E '^CCR_CONFIG_B64=' "$AGENT_HOME/.agent-env" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true)"
fi

if [ ! -f "$SIDECAR" ] && [ -n "${CCR_CONFIG_B64:-}" ]; then
  mkdir -p "$CCR_HOME/logs"
  if printf '%s' "$CCR_CONFIG_B64" | base64 -d > "$CCR_HOME/config.json.tmp" 2>/dev/null \
     && [ -s "$CCR_HOME/config.json.tmp" ]; then
    mv "$CCR_HOME/config.json.tmp" "$CCR_HOME/config.json"
    chown -R "${AGENT_USER}:${AGENT_USER}" "$CCR_HOME"
    chmod 600 "$CCR_HOME/config.json"
    log "ccr: config.json refreshed from a cloud-init CCR_CONFIG_B64 (no portal app row)"
  else
    rm -f "$CCR_HOME/config.json.tmp"
    log "WARN: CCR_CONFIG_B64 present but did not decode — keeping the existing config.json"
  fi
fi

# (Re)start so CCR boots with the derived sidecar in place (idempotent: restart starts
# a not-yet-running unit). WARN-not-die — Restart=always keeps retrying.
systemctl restart ccr.service >/dev/null 2>&1 \
  && log "ccr.service (re)started" \
  || log "WARN: could not start ccr.service — check 'journalctl -u ccr.service'"

# Bounded liveness poll: any HTTP response on :3456 means CCR is listening (a 404 is
# fine — we are checking the port answers, not a specific route). First boot may have
# no CCR app row yet (the operator adds one in the portal later); on timeout WARN +
# continue. The same probe is reported on every health snapshot (F5), so the portal
# sees this liveness for the life of the agent, not just at provision.
HEALTH_URL="http://127.0.0.1:3456"
MAX_WAIT_S=30
_waited=0
_ccr_up=0
while [ "$_waited" -lt "$MAX_WAIT_S" ]; do
  if curl -s -o /dev/null --max-time 3 "$HEALTH_URL" 2>/dev/null; then
    _ccr_up=1
    break
  fi
  sleep 3
  _waited=$((_waited + 3))
done

if [ "$_ccr_up" = "1" ]; then
  log "ccr: proxy answering on 127.0.0.1:3456"
else
  log "WARN: ccr did not answer on 127.0.0.1:3456 within ${MAX_WAIT_S}s."
  log "  Restart=always keeps retrying; if it never comes up, verify ${SIDECAR} (derived from the portal's CCR app) and 'journalctl -u ccr.service'."
fi
