# 19g-agent-reboot.sh — make an agent reboot actually reboot (SCRUM-1926).
#
# THE BUG: both portal reboot lanes reported success while the VM stayed up.
#   Lane 2 (portal -> daemon POST :9876/api/system/reboot) shelled out to
#   `sudo reboot` as the agent user. The agent's sudoers grants exactly two
#   wrappers (sb-self-update from base/08, sb-config-place from base/19f) and the
#   user is in no sudo group (base/09), so EVERY call was denied — journal:
#   `agent : command not allowed ; COMMAND=/usr/sbin/reboot` — while the daemon
#   still answered {"ok":true}. A deterministic, fleet-wide silent no-op.
#   Lane 1 (portal -> Hetzner soft ACPI reboot) reaches the guest as a power-key
#   press. lightdm + unity-greeter — an unpinned Recommends of xfce4 (base/04)
#   running an invisible Xorg on seat0, while the real desktop is Xvfb :10 + xrdp
#   (base/16) — hold a `handle-power-key` BLOCK inhibitor from boot, so logind
#   defers the event to the greeter, which "handles" it by drawing a power dialog
#   on a display nobody will ever see. Swallowed, with no log trace.
#
# THIS STEP installs both halves:
#   1. /usr/local/bin/sb-reboot + a narrow NOPASSWD sudoers rule scoped to ONLY
#      that wrapper, so the daemon has a real reboot path (and a real exit code to
#      report). Mirrors the sb-self-update / sb-config-place pattern exactly.
#   2. /etc/systemd/logind.conf.d/50-agent-power.conf pinning HandlePowerKey=poweroff
#      + PowerKeyIgnoreInhibited=yes, so Lane 1's ACPI press is honoured by logind
#      even while the greeter holds its inhibitor.
#
# WHY 19g AND NOT base/08: refresh-manifest.txt is what re-runs base steps on the
# LIVE fleet (via `sudo sb-self-update`, SCRUM-1380); steps 01..13 are provision-only.
# A sudoers grant added to base/08 would reach newly provisioned agents ONLY, leaving
# every existing box with the silent no-op. This step is listed in the manifest, so
# it reaches the whole fleet on the next pull_repos tick.
#
# IDEMPOTENT / REFRESH-SAFE: it installs no packages and only rewrites its own three
# artifacts, each byte-identical on a no-change run.
#
# logind is deliberately NOT restarted here. The drop-in takes effect at the next
# boot; restarting logind on a live box with active RDP/X sessions is a real risk for
# no gain, because the path we actually depend on (sb-reboot -> `systemctl reboot`)
# talks to systemd directly and never consults the power-key inhibitor. Fix 2 in the
# portal (verify the guest really cycled, escalate to a hard power-cycle when it did
# not) is what covers the window where this drop-in is written but not yet live.

step "Step 19g/16: privileged reboot wrapper + power-key policy"

# ── 1. the wrapper ───────────────────────────────────────────────────────────
REBOOT_WRAPPER_SRC="${BASE_DIR}/assets/sb-reboot.sh"
if [ -f "$REBOOT_WRAPPER_SRC" ]; then
  install -m 0755 "$REBOOT_WRAPPER_SRC" /usr/local/bin/sb-reboot \
    && log "sb-reboot wrapper installed" \
    || log "WARN: could not install sb-reboot wrapper"
else
  log "WARN: sb-reboot asset missing ($REBOOT_WRAPPER_SRC) — agent reboot stays a no-op"
fi

# ── 2. narrow NOPASSWD sudoers, scoped to ONLY the wrapper ───────────────────
# Written only when the wrapper exists, so a failed install can never leave a
# grant pointing at a missing binary. Validated with visudo and removed on a
# parse error — a broken /etc/sudoers.d file breaks sudo for the whole box,
# including sb-self-update, which is how the fleet would be repaired.
if [ -x /usr/local/bin/sb-reboot ]; then
  cat > /etc/sudoers.d/sb-reboot <<EOF
# Let the agent reboot its own VM through the audited sb-reboot wrapper, without a
# password — scoped to this one wrapper only (SCRUM-1926). The wrapper is the whole
# trust boundary: sudoers cannot constrain arguments, and it takes none.
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/sb-reboot
EOF
  chmod 0440 /etc/sudoers.d/sb-reboot
  if visudo -cf /etc/sudoers.d/sb-reboot >/dev/null 2>&1; then
    log "sb-reboot: narrow sudoers installed"
  else
    rm -f /etc/sudoers.d/sb-reboot
    log "WARN: sb-reboot sudoers failed validation — removed (agent reboot disabled)"
  fi
fi

# ── 3. power-key policy: never let the greeter own the power button ──────────
# HandlePowerKey=poweroff is already the logind default, but it is only reached
# when nothing holds a handle-power-key inhibitor. PowerKeyIgnoreInhibited=yes is
# the load-bearing line: it makes logind act on the press regardless of the
# greeter's BLOCK inhibitor. Pinning both keeps the file self-describing.
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/50-agent-power.conf <<'EOF'
# SideButton agent image — power-key policy (SCRUM-1926).
#
# A Hetzner "reboot" action is a soft ACPI power-button press. lightdm's
# unity-greeter (an unpinned Recommends of xfce4, running an invisible Xorg on
# seat0) holds a `handle-power-key` BLOCK inhibitor from boot, so logind used to
# defer the press to the greeter, which swallowed it on a display no human sees —
# leaving the portal reporting a reboot that never happened.
#
# PowerKeyIgnoreInhibited=yes makes logind act on the press itself. Safe on this
# image: it is headless (the real desktop is Xvfb :10 + xrdp, independent of
# lightdm) and nothing here needs to veto a power-off.
#
# Takes effect at the next boot. Managed by base/19g-agent-reboot.sh — edits are
# overwritten on the next fleet refresh.
[Login]
HandlePowerKey=poweroff
PowerKeyIgnoreInhibited=yes
EOF
chmod 0644 /etc/systemd/logind.conf.d/50-agent-power.conf
log "logind power-key policy installed (active from next boot)"
