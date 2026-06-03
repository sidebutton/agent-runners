# 19d-account-registry.sh — add the per-account knowledge-pack registry (deferred
# from base/13) and install a timer that keeps it fresh.
#
# The universal `agents` ops pack is installed anonymously in base/13. A private
# per-account registry (SIDEBUTTON_DEFAULT_REGISTRY, forwarded by the portal) is
# ADDITIVE — installed here ON TOP of it — and is deferred to this point, AFTER
# secrets land in base/19, because cloning a private git repo needs credentials:
# SIDEBUTTON_DEFAULT_REGISTRY_TOKEN arrives in ~/.agent-env via the secrets fetch,
# which is empty at base/13 time. Running the add here (and re-reading ~/.agent-env
# at call time inside /opt/sb-registry-sync.sh) avoids the could-not-read-Username
# timing failure class that bit private clones in SCRUM-1122/1124.
#
# The sb-registry-update timer then reconciles (re-adds the configured registry if the
# one-shot add above failed) and git-pulls it on a schedule mirroring the sb-health
# reporter (base/19c), so a transient first-add failure self-heals and SD-pushed
# modules reach running agents (SCRUM-1167).
#
# Gated by SKIP_KNOWLEDGE_PACKS (the bare ubuntu-claude-code variant ships no
# registry) and only runs when an account registry is actually configured — the
# public catalog pack from base/13 is not a git registry and needs no pulling.

if [ "${SKIP_KNOWLEDGE_PACKS:-}" = "1" ]; then
  step "Step 19d/16: Account knowledge-pack registry (skipped — SKIP_KNOWLEDGE_PACKS=1)"
elif [ -z "${SIDEBUTTON_DEFAULT_REGISTRY:-}" ]; then
  step "Step 19d/16: Account knowledge-pack registry (none configured — SIDEBUTTON_DEFAULT_REGISTRY unset)"
else
  step "Step 19d/16: Account knowledge-pack registry (${SIDEBUTTON_DEFAULT_REGISTRY})"

  SYNC_SRC="${BASE_DIR}/assets/sb-registry-sync.sh"
  SYNC_DEST="/opt/sb-registry-sync.sh"
  if [ ! -f "$SYNC_SRC" ]; then
    log "WARN: bundled sync helper missing (${SYNC_SRC}) — account registry not installed"
  else
    install -m 0755 "$SYNC_SRC" "$SYNC_DEST"
    log "registry sync helper installed: ${SYNC_DEST}"

    # Persist the registry URL into ~/.agent-env so the recurring sb-registry-update
    # timer can RECONCILE (add-if-missing). Without this the timer has no way to know
    # the desired registry, so the one-shot add below — which can fail transiently when
    # the credential lands only after a later config-apply — never self-heals (SCRUM-1167).
    # systemd EnvironmentFile format: KEY="VALUE", no export, no shell expansion.
    REG_ENV_FILE="${AGENT_HOME}/.agent-env"
    if grep -q '^SIDEBUTTON_DEFAULT_REGISTRY=' "$REG_ENV_FILE" 2>/dev/null; then
      sed -i "s|^SIDEBUTTON_DEFAULT_REGISTRY=.*|SIDEBUTTON_DEFAULT_REGISTRY=\"${SIDEBUTTON_DEFAULT_REGISTRY}\"|" "$REG_ENV_FILE"
    else
      echo "SIDEBUTTON_DEFAULT_REGISTRY=\"${SIDEBUTTON_DEFAULT_REGISTRY}\"" >> "$REG_ENV_FILE"
    fi
    chown "${AGENT_USER}:${AGENT_USER}" "$REG_ENV_FILE" 2>/dev/null || true
    log "persisted SIDEBUTTON_DEFAULT_REGISTRY to ${REG_ENV_FILE} (timer reconcile)"

    # One-time add now that secrets (the token in ~/.agent-env) are present. The
    # helper sources ~/.agent-env and authenticates with SIDEBUTTON_DEFAULT_REGISTRY_TOKEN.
    # If this fails (token not yet delivered), the sb-registry-update timer reconciles
    # it (add-if-missing) on its next tick — see base/assets/sb-registry-sync.sh.
    if su - "$AGENT_USER" -c "${SYNC_DEST} add '${SIDEBUTTON_DEFAULT_REGISTRY}'"; then
      log "account registry added: ${SIDEBUTTON_DEFAULT_REGISTRY}"
    else
      log "WARN: registry add failed — account modules unavailable until rerun (${SYNC_DEST} add) as ${AGENT_USER}"
    fi

    # Oneshot service — runs the helper in update mode as the agent user with the
    # agent env. It re-sources ~/.agent-env itself, so the EnvironmentFile is just
    # belt-and-suspenders (HOME, plus any vars the helper might read directly).
    cat > /etc/systemd/system/sb-registry-update.service <<'EOF'
[Unit]
Description=SideButton account knowledge-pack registry update (git pull)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=agent
EnvironmentFile=/home/agent/.agent-env
TimeoutStartSec=180
ExecStart=/opt/sb-registry-sync.sh update
EOF

    # Timer — cadence mirrors sb-health (every 5 min). The one-time add above is
    # the immediate first sync; each tick also reconciles (add-if-missing) so a failed
    # first add recovers within ~5 min. The boot timer (reboots only) waits 2 min for
    # the network to settle rather than racing other boot-time work.
    cat > /etc/systemd/system/sb-registry-update.timer <<'EOF'
[Unit]
Description=Pull the SideButton account knowledge-pack registry every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now sb-registry-update.timer >/dev/null 2>&1 \
      || log "WARN: failed to enable sb-registry-update.timer"
    log "sb-registry-update enabled (git pull every 5min; +immediate add above)"
  fi
fi
