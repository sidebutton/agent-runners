# components/claude-code-router/post-services.sh — start CCR + health-check.
#
# Sourced by base/run.sh at the post-services phase (after 19b) when
# `claude-code-router` is selected — i.e. AFTER 19-secrets has populated
# ~/.agent-env, so this is the first start of ccr.service (install.sh only ENABLED
# it). Mirrors the sidebutton-extension post-services pattern: best-effort, runs
# under run.sh's `set -euo pipefail`, so every probe must WARN-not-die.

step "Starting Claude Code Router (CCR) + health probe"

CCR_HOME="$AGENT_HOME/.claude-code-router"
ENV_FILE="$AGENT_HOME/.agent-env"

# CCR_CONFIG_B64 can arrive two ways: cloud-init env (already in this shell) or
# delivered into ~/.agent-env by 19-secrets (this root shell never sourced it).
# Pick up the latter WITHOUT importing every secret into run.sh's environment —
# read just this one key and strip the surrounding quotes 19-secrets writes. The
# trailing `|| true` is REQUIRED: this script is sourced into run.sh's `set -euo
# pipefail` shell, so when the key is absent (the common case — CCR_CONFIG_B64 is
# optional) grep exits 1, pipefail propagates it to the assignment, and set -e
# would abort the whole provision. `|| true` keeps the no-match → empty path.
if [ -z "${CCR_CONFIG_B64:-}" ] && [ -f "$ENV_FILE" ]; then
  CCR_CONFIG_B64="$(grep -E '^CCR_CONFIG_B64=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true)"
fi

# If a whole-config override was delivered post-install, decode it now (install.sh
# could not — it ran before 19-secrets). Atomic + validated; keep the prior config
# on a bad decode. The template path needs nothing here: CCR interpolates the now
# complete ~/.agent-env at (re)start via its systemd EnvironmentFile.
if [ -n "${CCR_CONFIG_B64:-}" ]; then
  mkdir -p "$CCR_HOME/logs"
  if printf '%s' "$CCR_CONFIG_B64" | base64 -d > "$CCR_HOME/config.json.tmp" 2>/dev/null \
     && [ -s "$CCR_HOME/config.json.tmp" ]; then
    mv "$CCR_HOME/config.json.tmp" "$CCR_HOME/config.json"
    chown -R "${AGENT_USER}:${AGENT_USER}" "$CCR_HOME"
    chmod 600 "$CCR_HOME/config.json"
    log "ccr: config.json refreshed from CCR_CONFIG_B64 (agent-env delivery)"
  else
    rm -f "$CCR_HOME/config.json.tmp"
    log "WARN: CCR_CONFIG_B64 present in ~/.agent-env but did not decode — keeping the existing config.json"
  fi
fi

# (Re)start so CCR boots with the complete ~/.agent-env (idempotent: restart starts
# a not-yet-running unit). WARN-not-die — Restart=always keeps retrying.
systemctl restart ccr.service >/dev/null 2>&1 \
  && log "ccr.service (re)started" \
  || log "WARN: could not start ccr.service — check 'journalctl -u ccr.service'"

# Bounded liveness poll: any HTTP response on :3456 means CCR is listening (a 404 is
# fine — we are checking the port answers, not a specific route). First boot may have
# no routing env yet (T6/operator delivers it later); on timeout WARN + continue.
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
  log "  Restart=always keeps retrying; if it never comes up, verify ANTHROPIC_*/CCR_PROVIDER_* in ${ENV_FILE} and 'journalctl -u ccr.service'."
fi
