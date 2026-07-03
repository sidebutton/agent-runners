# 19f-component-config.sh — default-path config-file consumption for components
# (SCRUM-1599, epic SCRUM-1597).
#
# Installs the ONE privileged placement wrapper (sb-config-place) + its narrow
# NOPASSWD sudoers rule (same pattern as sb-self-update in base/08), the reconcile
# helper (sb-config-reconcile), a templated apply service, and — for each installed
# component that declares config files — a per-slug descriptor + a systemd path-unit
# watcher on its default target_path. A profile that lands there (portal push via
# sb-config-place, or manual SSH) is auto-applied at boot and on change; removal
# tears the tunnel/service down. The manual sb-*-connect helpers stay break-glass.
#
# KEYSTONE — why this is ONE central base step, not per-component install.sh logic:
# refresh-manifest.txt re-runs base steps on the live fleet via `sudo sb-self-update`
# (SCRUM-1380), and that refresh runs WITHOUT AGENT_COMPONENTS / has_component (those
# are provision-only cloud-init, never persisted). Component install.sh scripts also
# apt-get, so they are not refresh-safe. So detection here is by a FILESYSTEM signal —
# the component's installed helper (/usr/local/bin/sb-wg-connect …) — which is stable
# at both provision (this step runs after the toolchain loop in run.sh) and refresh.
# Fully idempotent: it re-writes only declarations/units (never apt), and the boot
# reconcile is sha-gated so a routine pull_repos never bounces a live tunnel.

step "Step 19f/16: component config-file watchers + sb-config-place"

# ── 1. privileged placement wrapper + reconcile helper (from assets) ─────────
WRAPPER_SRC="${BASE_DIR}/assets/sb-config-place.sh"
if [ -f "$WRAPPER_SRC" ]; then
  install -m 0755 "$WRAPPER_SRC" /usr/local/bin/sb-config-place \
    && log "sb-config-place wrapper installed" \
    || log "WARN: could not install sb-config-place wrapper"
else
  log "WARN: sb-config-place asset missing ($WRAPPER_SRC) — config delivery disabled"
fi

RECONCILE_SRC="${BASE_DIR}/assets/sb-config-reconcile.sh"
if [ -f "$RECONCILE_SRC" ]; then
  install -m 0755 "$RECONCILE_SRC" /usr/local/bin/sb-config-reconcile \
    && log "sb-config-reconcile helper installed" \
    || log "WARN: could not install sb-config-reconcile helper"
else
  log "WARN: sb-config-reconcile asset missing ($RECONCILE_SRC)"
fi

# Narrow NOPASSWD sudoers scoped to ONLY the placement wrapper (mirrors base/08's
# sb-self-update rule). The agent server (non-root) stages an upload, then calls
# `sudo sb-config-place …`; the wrapper is the whole trust boundary (it validates the
# target against the installed component's declared path). sudoers cannot constrain
# args, so nothing else is granted.
if [ -x /usr/local/bin/sb-config-place ]; then
  cat > /etc/sudoers.d/sb-config-place <<EOF
# Let the agent place a validated component config file at its declared target path
# (root:600) without a password — scoped to this one wrapper only.
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/sb-config-place
EOF
  chmod 0440 /etc/sudoers.d/sb-config-place
  if visudo -cf /etc/sudoers.d/sb-config-place >/dev/null 2>&1; then
    log "sb-config-place: narrow sudoers installed"
  else
    rm -f /etc/sudoers.d/sb-config-place
    log "WARN: sb-config-place sudoers failed validation — removed (portal delivery disabled)"
  fi
fi

# ── 2. templated apply service: one instance per slug runs the reconcile ─────
# The path-unit watcher (§4) triggers sb-config-apply@<slug>.service on change.
cat > /etc/systemd/system/sb-config-apply@.service <<'EOF'
[Unit]
Description=Apply SideButton component config files for %i
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb-config-reconcile %i
EOF

# ── 3. per-component wiring, keyed off the installed helper (filesystem signal) ─
mkdir -p /etc/sidebutton/components
WIRED_SLUGS=""

# _sb_wire_config <slug> <signal_bin> <target_path> <multiple> <accept> \
#                 <consume> <helper_bin> <service> <name_max> <watch_kind:dir|file>
# Writes the descriptor + (for dirs) creates the watched dir + writes the per-slug
# .path unit. Detection: skip unless the component's helper is installed. The .path
# units are CONCRETE (not template instances) because their WatchPath differs per
# component (a dir for wg/openvpn, the single rdp.env file) and a .path template
# cannot vary its PathModified per instance.
_sb_wire_config() {
  local slug="$1" signal_bin="$2" target_path="$3" multiple="$4" accept="$5" \
        consume="$6" helper_bin="$7" service="$8" name_max="$9" watch_kind="${10}"
  [ -x "$signal_bin" ] || { log "config: '${slug}' not installed (${signal_bin} absent) — skipped"; return 0; }

  cat > "/etc/sidebutton/components/${slug}.conf" <<EOF
slug=${slug}
target_path=${target_path}
multiple=${multiple}
accept=${accept}
consume=${consume}
helper_bin=${helper_bin}
service=${service}
name_max=${name_max}
EOF
  chmod 0600 "/etc/sidebutton/components/${slug}.conf"

  local unit="/etc/systemd/system/sb-config-watch-${slug}.path"
  if [ "$watch_kind" = "dir" ]; then
    # Watched dir holds secrets (private keys) — root:700; files land root:600.
    mkdir -p "${target_path%/}"
    chmod 0700 "${target_path%/}"
    cat > "$unit" <<EOF
[Unit]
Description=Watch ${slug} component config dir (${target_path})

[Path]
# DirectoryNotEmpty ⇒ boot-time apply when files are already present;
# PathModified ⇒ apply/tear-down as files are added, changed, or removed.
DirectoryNotEmpty=${target_path}
PathModified=${target_path}
Unit=sb-config-apply@${slug}.service

[Install]
WantedBy=multi-user.target
EOF
  else
    mkdir -p "$(dirname "$target_path")"
    cat > "$unit" <<EOF
[Unit]
Description=Watch ${slug} component config file (${target_path})

[Path]
PathExists=${target_path}
PathModified=${target_path}
Unit=sb-config-apply@${slug}.service

[Install]
WantedBy=multi-user.target
EOF
  fi
  WIRED_SLUGS="${WIRED_SLUGS} ${slug}"
  log "config: '${slug}' wired → watches ${target_path}"
}

#             slug        signal / helper                target_path                          mult accept  consume helper_bin                     service  name_max watch
_sb_wire_config wireguard  /usr/local/bin/sb-wg-connect  /etc/sidebutton/config/wireguard/    1    .conf   helper  /usr/local/bin/sb-wg-connect   ""       15       dir
_sb_wire_config openvpn    /usr/local/bin/sb-vpn-connect /etc/sidebutton/config/openvpn/      1    .ovpn   helper  /usr/local/bin/sb-vpn-connect  ""       ""       dir
_sb_wire_config rdp-client /usr/local/bin/sb-rdp-connect /etc/sidebutton/rdp.env              0    .env    service ""                             sb-rdp   ""       file

# ── 4. activate: reload, boot-reconcile once, enable the watchers ────────────
systemctl daemon-reload >/dev/null 2>&1 || log "WARN: systemctl daemon-reload failed"
for _slug in $WIRED_SLUGS; do
  # Deterministic provision-time apply of anything already present (fast no-op on an
  # empty dir), THEN enable the watcher for ongoing + boot-time apply. Ordering the
  # explicit reconcile first avoids racing the watcher's immediate --now trigger.
  if [ -x /usr/local/bin/sb-config-reconcile ]; then
    /usr/local/bin/sb-config-reconcile "$_slug" >/dev/null 2>&1 || log "WARN: initial reconcile of '${_slug}' reported an error"
  fi
  systemctl enable --now "sb-config-watch-${_slug}.path" >/dev/null 2>&1 \
    || log "WARN: could not enable sb-config-watch-${_slug}.path"
done
unset -f _sb_wire_config

log "component config: wired [${WIRED_SLUGS:-none}] (sb-config-place + per-slug path watchers)"
