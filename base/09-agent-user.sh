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

# Swap — a 4 GB file on the host, and NOTHING inside a container.
#
# WHY THE GUARD IS LOAD-BEARING, not defensive style: run.sh is `set -euo pipefail`
# and every step is SOURCED into that same shell, so an unguarded failure here kills
# the whole install at step 9 of 16 — before the desktop, before the SB server,
# before the heartbeat ever registers the agent. Two real ways that happened:
#
#   1. In a container. `swapon` is a kernel-GLOBAL operation a container must not
#      perform (it would add the file to the host kernel's swap), and on overlayfs
#      `fallocate` returns EOPNOTSUPP before we even reach it. A container already
#      inherits its host's swap and is bounded by its own cgroup limits, so there
#      is nothing here to create. Proven 2026-09-19 on a Docker/WSL2 agent: with
#      this guard the step logs the inherited swap and the install completes.
#   2. On a host filesystem that cannot fallocate (ZFS, some network mounts). Rarer,
#      same fatal ending — so each command below tolerates its own failure and
#      degrades to "no swap" rather than taking the install down with it.
if systemd-detect-virt -c -q 2>/dev/null || [ -f /.dockerenv ]; then
  log "swap: skipped (container: $(systemd-detect-virt -c 2>/dev/null || echo docker)) — inherited from the host"
elif [ -f /swapfile ]; then
  log "swap: /swapfile already present — leaving it alone"
elif ! fallocate -l 4G /swapfile 2>/dev/null; then
  rm -f /swapfile
  log "WARN: cannot allocate /swapfile on this filesystem — continuing without swap"
elif chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  rm -f /swapfile
  log "WARN: could not enable /swapfile — continuing without swap"
fi
log "swap: $(free -h | awk '/Swap:/{print $2}')"
