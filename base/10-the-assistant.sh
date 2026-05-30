# 10-the-assistant.sh — Clone the private the-assistant repo (Chrome extension
# source + agent docs). Best-effort: a fresh VM has no GH credentials yet, so
# the clone may fail. The operator is expected to configure GH_TOKEN later.

step "Step 10/16: the-assistant repo"
if [ ! -d "$AGENT_HOME/ops/the-assistant/.git" ]; then
  rm -rf "$AGENT_HOME/ops/the-assistant"
  git clone --depth 1 https://github.com/sidebutton/the-assistant.git "$AGENT_HOME/ops/the-assistant" 2>/dev/null \
    || log "WARN: could not clone the-assistant (private repo) — operator must configure GH_TOKEN and clone manually"
else
  log "the-assistant: already present"
fi
