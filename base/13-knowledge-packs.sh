# 13-knowledge-packs.sh — install the default knowledge-pack registry.
#
# Fresh agents need the universal "agents" knowledge pack — it ships the ops
# workflows (agent_pull_repos / ln, pm-drive, …) that orchestrator dispatch
# fires over HTTP on the agent. Without them every agent-side child workflow
# returns HTTP 404 "Workflow not found" (SCRUM-1073).
#
# Default (OSS): `sidebutton install agents` pulls the pack from the public
# sidebutton.com catalog API — anonymous, no git credentials required.
#
# Enterprise/self-hosted: set SIDEBUTTON_DEFAULT_REGISTRY (forwarded by the
# portal provisioner) to register a private/self-hosted git registry the
# agent has access to.

step "Step 13/16: Default knowledge-pack registry"
chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
if [ -n "${SIDEBUTTON_DEFAULT_REGISTRY:-}" ]; then
  if su - "$AGENT_USER" -c "sidebutton registry add '${SIDEBUTTON_DEFAULT_REGISTRY}' 2>&1"; then
    log "registry added: ${SIDEBUTTON_DEFAULT_REGISTRY}"
  else
    log "WARN: 'sidebutton registry add ${SIDEBUTTON_DEFAULT_REGISTRY}' failed (private registry needs agent git access) — agent-side workflows unavailable until rerun as ${AGENT_USER}"
  fi
else
  if su - "$AGENT_USER" -c "sidebutton install agents 2>&1"; then
    log "knowledge pack installed: agents (ops workflows)"
  else
    log "WARN: 'sidebutton install agents' failed — agent-side workflows unavailable until rerun as ${AGENT_USER}"
  fi
fi
