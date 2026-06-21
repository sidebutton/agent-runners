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

# Hooks live in base/assets/claude-hooks.json — single source of truth shared
# with the-assistant's agent-redeploy.sh, which re-merges the block onto existing
# boxes (this step only runs at provision time). The referenced helper scripts
# (sb-mark-tool-use.sh, sb-session-id.sh, claude-stop-hook.sh) are installed by
# base/14 before any Claude job runs.
jq -n --slurpfile h "$BASE_DIR/assets/claude-hooks.json" '{
  skipDangerousModePermissionPrompt: true,
  env: { DISABLE_AUTOUPDATER: "1" },
  hooks: $h[0].hooks
}' > "$AGENT_HOME/.claude/settings.json"

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
