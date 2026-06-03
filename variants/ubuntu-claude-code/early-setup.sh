# early-setup.sh — variant overlay (ubuntu-claude-code)
#
# Runs after 01-preflight.sh and before any install step. Declares which base
# steps to skip so the bare variant doesn't ship the SideButton runtime.
#
# Why these specific skips:
#   * SKIP_SIDEBUTTON_SERVER=1 — drops 08-sidebutton.sh (npm install -g sidebutton),
#     drops the sidebutton.service unit in 16-services-prep.sh, removes it from
#     the enable/start list in 17-services-start.sh, and reports "not-installed"
#     in the heartbeat dependency_versions.sidebutton field (18).
#   * SKIP_KNOWLEDGE_PACKS=1 — drops 13-knowledge-packs.sh and
#     19d-account-registry.sh. Knowledge packs are served via the SB MCP server,
#     which the bare variant doesn't run; `sidebutton install agents` / `registry
#     add` would also fail without the binary.
#
# Step 15 (claude-mcp registration) gates on the same SKIP_SIDEBUTTON_SERVER
# flag — there's no SB MCP endpoint on :9876 to register against.

export SKIP_SIDEBUTTON_SERVER=1
export SKIP_KNOWLEDGE_PACKS=1
log "early-setup: SKIP_SIDEBUTTON_SERVER=1 SKIP_KNOWLEDGE_PACKS=1 (bare variant)"
