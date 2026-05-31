# 09-agent-user.sh — Agent user, base directories, claude settings, swap.

step "Step 9/16: Agent user + swap"
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
  log "created user: ${AGENT_USER}"
fi
echo "${AGENT_USER}:${AGENT_PASSWORD}" | chpasswd

mkdir -p "$AGENT_HOME/.config" "$AGENT_HOME/.claude" "$AGENT_HOME/.sidebutton" \
         "$AGENT_HOME/ops/logs" "$AGENT_HOME/workspace" "$AGENT_HOME/.local/bin"

cat > "$AGENT_HOME/.xsessionrc" <<'EOF'
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
EOF
cat > "$AGENT_HOME/.xsession" <<'EOF'
startxfce4
EOF
chmod +x "$AGENT_HOME/.xsession"

cat > "$AGENT_HOME/.claude/settings.json" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true,
  "env": { "DISABLE_AUTOUPDATER": "1" },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "TaskCreate|TaskUpdate",
        "hooks": [
          { "type": "command", "command": "cat >> $HOME/ops/logs/task-events.jsonl" },
          { "type": "command", "command": "curl -4 -sf -X POST $PORTAL_URL/api/agents/events -H 'Content-Type: application/json' -H \"Authorization: Bearer $AGENT_TOKEN\" -H \"X-Agent-Name: $AGENT_NAME\" -d @- --max-time 5 2>/dev/null || true" }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "date -u +%Y-%m-%dT%H:%M:%SZ > $HOME/.sidebutton/last-tool-use" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.local/bin/claude-stop-hook.sh" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.local/bin/claude-stop-hook.sh" }
        ]
      }
    ]
  }
}
EOF

# Pre-seed Claude Code's global state so the FIRST `claude` run skips the
# interactive first-run onboarding (theme picker / "Let's get started"). Agent
# jobs launch `claude --dangerously-skip-permissions "<prompt>"` non-interactively
# in a terminal: that flag bypasses the trust/permission prompts but NOT the
# onboarding, which is gated separately on hasCompletedOnboarding in
# ~/.claude.json. Without this the job terminal hangs forever on the theme picker.
# base/15 later chowns $AGENT_HOME to the agent and runs `claude mcp add`, which
# merges its server entry into this file (the onboarding flag is preserved).
if [ ! -f "$AGENT_HOME/.claude.json" ]; then
  cat > "$AGENT_HOME/.claude.json" <<'EOF'
{
  "hasCompletedOnboarding": true,
  "theme": "dark"
}
EOF
fi

if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
log "swap: $(free -h | awk '/Swap:/{print $2}')"
