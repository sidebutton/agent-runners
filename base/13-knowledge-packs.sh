# 13-knowledge-packs.sh — install the universal "agents" ops knowledge pack.
#
# Fresh agents need the universal "agents" knowledge pack — it ships the ops
# workflows (agent_pull_repos / ln, pm-drive, …) that orchestrator dispatch
# fires over HTTP on the agent. Without them every agent-side child workflow
# returns HTTP 404 "Workflow not found" (SCRUM-1073).
#
# `sidebutton install agents` pulls the pack from the public sidebutton.com
# catalog API — anonymous, no git credentials required — so it installs safely
# HERE, before per-agent secrets land (base/19).
#
# Packs are ADDITIVE: a per-account/self-hosted registry (SIDEBUTTON_DEFAULT_REGISTRY,
# forwarded by the portal) is installed ON TOP of this pack, not instead of it.
# That add is a private git clone needing GH_TOKEN/SIDEBUTTON_DEFAULT_REGISTRY_TOKEN,
# which are still empty at this point, so it is DEFERRED to base/19d (post-secrets)
# to dodge the could-not-read-Username timing failure class (cf. SCRUM-1122/1124).

if [ "${SKIP_KNOWLEDGE_PACKS:-}" = "1" ]; then
  step "Step 13/16: Universal 'agents' ops pack (skipped — SKIP_KNOWLEDGE_PACKS=1)"
else
  step "Step 13/16: Universal 'agents' ops pack"
  chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"
  if su - "$AGENT_USER" -c "sidebutton install agents 2>&1"; then
    log "knowledge pack installed: agents (ops workflows)"
  else
    log "WARN: 'sidebutton install agents' failed — agent-side workflows unavailable until rerun as ${AGENT_USER}"
  fi
fi
