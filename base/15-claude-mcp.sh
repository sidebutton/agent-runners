# 15-claude-mcp.sh — register the SideButton MCP transport in Claude Code.
#
# Skipped when SKIP_SIDEBUTTON_SERVER=1 — there is no MCP server on :9876 to
# register against (set by variants like ubuntu-claude-code).

step "Step 15/16: Register Claude MCP servers"
# Runs before every claude mcp add: ~/.claude.json is root-owned until here.
chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"

# SideButton transport — skipped when there is no :9876 server to register
# against (variants like ubuntu-claude-code set SKIP_SIDEBUTTON_SERVER=1).
if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  log "SideButton MCP transport skipped (SKIP_SIDEBUTTON_SERVER=1)"
else
  su - "$AGENT_USER" -c 'cd ~/workspace && claude mcp add sidebutton --transport sse http://localhost:9876/mcp -s project' 2>/dev/null \
    || log "WARN: claude mcp add sidebutton failed — re-run as agent after login"
fi

# mobile-mcp lets Claude Code drive the Android AVD (accessibility-tree taps/reads
# over adb). Independent of the SideButton server, so NOT gated on
# SKIP_SIDEBUTTON_SERVER. User scope (not project) so it survives workspace
# .mcp.json rewrites; the android-emulator component pre-installs the
# `mcp-server-mobile` bin. Pinned to 0.0.62 — its tools take an explicit `device`.
if has_component android-emulator; then
  su - "$AGENT_USER" -c 'claude mcp add mobile-mcp -s user -e ANDROID_HOME=/opt/android-sdk -- mcp-server-mobile' 2>/dev/null \
    || log "WARN: claude mcp add mobile-mcp failed — re-run as agent after login"
fi
