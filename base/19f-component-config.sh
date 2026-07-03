# 19f-component-config.sh — component config-file consumption (SCRUM-1599, A1).
#
# Wires up the agent side of "drop a VPN/RDP profile at its default path and it just
# applies": the privileged sb-config-place wrapper (+ narrow sudoers), the reconcile
# engine, the templated systemd path-watch/apply units, and — for each config-declaring
# component actually installed on THIS box — a per-slug descriptor + path watcher +
# one boot-time reconcile. Manual-SSH placement and (future, A3) portal delivery then
# converge on identical behaviour; the manual sb-*-connect helpers stay break-glass.
#
# WHY A CENTRAL BASE STEP (not each component's install.sh): this must reach the
# EXISTING fleet via refresh-manifest.txt + sb-self-update (SCRUM-1380). Refresh-time
# steps re-run WITHOUT has_component/AGENT_COMPONENTS (provision-only cloud-init, never
# persisted to .agent-env), and component install.sh scripts apt-get (not refresh-safe)
# — so neither can carry the watcher. This step therefore detects each config-declaring
# component by a FILESYSTEM SIGNAL (its installed helper, e.g. /usr/local/bin/
# sb-wg-connect) so provision and refresh behave identically. It runs after the
# toolchain loop (base/run.sh), so the helper it keys off is already present.
#
# Refresh-safe + idempotent: installs scripts/units/sudoers and enables watch units;
# NO apt. The reconcile it triggers is SHA-gated, so a routine sb-self-update tick where
# nothing changed never bounces a live tunnel. Sourced (not executed) — never `exit`.

step "Step 19f/16: Component config-file consumption"

_CFG_BASE="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
_CFG_CATALOG="${_CFG_BASE%/}/../components.json"
_CFG_ASSETS="${_CFG_BASE%/}/assets"
_CFG_ETC=/etc/sidebutton
_CFG_COMP_DIR="${_CFG_ETC}/components"
_CFG_UNIT_DIR=/etc/systemd/system

# Per-slug on-box runtime: "<helper>|<mode>|<service>". The catalog owns target_path/
# accept/multiple; this map owns how the file is consumed. A component with no mapping
# is skipped (add it here when a new component declares config_files).
_cfg_slug_runtime() {
  case "$1" in
    wireguard)  echo "/usr/local/bin/sb-wg-connect|profile-dir|" ;;
    openvpn)    echo "/usr/local/bin/sb-vpn-connect|profile-dir|" ;;
    rdp-client) echo "/usr/local/bin/sb-rdp-connect|env-file|sb-rdp" ;;
    *)          echo "||" ;;
  esac
}

# ── 1. privileged wrapper + reconcile engine (installed on ALL agents) ─────────
install -d -m 0755 "$_CFG_ETC"      2>/dev/null || log "WARN: could not create ${_CFG_ETC}"
install -d -m 0700 "$_CFG_COMP_DIR" 2>/dev/null || log "WARN: could not create ${_CFG_COMP_DIR}"

if [ -f "${_CFG_ASSETS}/sb-config-place.sh" ]; then
  install -m 0755 "${_CFG_ASSETS}/sb-config-place.sh" /usr/local/bin/sb-config-place \
    && log "sb-config-place wrapper installed (privileged config placement)" \
    || log "WARN: could not install sb-config-place"
else
  log "WARN: sb-config-place asset missing (${_CFG_ASSETS}/sb-config-place.sh)"
fi
if [ -f "${_CFG_ASSETS}/sb-config-reconcile.sh" ]; then
  install -m 0755 "${_CFG_ASSETS}/sb-config-reconcile.sh" /usr/local/bin/sb-config-reconcile \
    && log "sb-config-reconcile installed (default-path apply engine)" \
    || log "WARN: could not install sb-config-reconcile"
else
  log "WARN: sb-config-reconcile asset missing (${_CFG_ASSETS}/sb-config-reconcile.sh)"
fi

# ── 2. narrow NOPASSWD sudoers — scoped to ONLY the place wrapper (mirror base/08) ─
cat > /etc/sudoers.d/sb-config-place <<EOF
# Let the agent server stage-and-place component config files via the one hardened
# wrapper (it validates the slug + confines writes to the component's declared
# target_path), without a password — scoped to this one wrapper only. SCRUM-1599.
${AGENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/sb-config-place
EOF
chmod 0440 /etc/sudoers.d/sb-config-place 2>/dev/null || true
if visudo -cf /etc/sudoers.d/sb-config-place >/dev/null 2>&1; then
  log "sb-config-place: narrow sudoers installed"
else
  rm -f /etc/sudoers.d/sb-config-place
  log "WARN: sb-config-place sudoers failed validation — removed (config placement disabled)"
fi

# ── 3. templated systemd units (watch → apply) ────────────────────────────────
for _u in sb-config-apply@.service sb-config-watch@.path; do
  if [ -f "${_CFG_ASSETS}/${_u}" ]; then
    install -m 0644 "${_CFG_ASSETS}/${_u}" "${_CFG_UNIT_DIR}/${_u}" \
      && log "installed unit template ${_u}" \
      || log "WARN: could not install unit template ${_u}"
  else
    log "WARN: unit template asset missing: ${_u}"
  fi
done
systemctl daemon-reload >/dev/null 2>&1 || true

# ── 4. per config-declaring component detected on THIS box ─────────────────────
if command -v jq >/dev/null 2>&1 && [ -r "$_CFG_CATALOG" ]; then
  _cfg_slugs="$(jq -r '.components[] | select((.config_files // []) | length > 0) | .slug' "$_CFG_CATALOG" 2>/dev/null || true)"
  for _slug in $_cfg_slugs; do
    _rt="$(_cfg_slug_runtime "$_slug")"
    _helper="${_rt%%|*}"; _rest="${_rt#*|}"; _mode="${_rest%%|*}"; _service="${_rest#*|}"
    if [ -z "$_mode" ]; then
      log "config: no on-box runtime mapping for '${_slug}' — skipping (add it to base/19f)"; continue
    fi
    # Filesystem-signal detection: the component's helper implies it was installed here.
    if [ -z "$_helper" ] || [ ! -x "$_helper" ]; then
      log "config: '${_slug}' not installed on this agent (no ${_helper}) — no watcher"; continue
    fi

    _tp="$(jq -r --arg s "$_slug" '.components[]|select(.slug==$s)|.config_files[0].target_path' "$_CFG_CATALOG" 2>/dev/null || true)"
    _multi="$(jq -r --arg s "$_slug" '.components[]|select(.slug==$s)|(.config_files[0].multiple // false)' "$_CFG_CATALOG" 2>/dev/null || true)"
    _accept="$(jq -r --arg s "$_slug" '.components[]|select(.slug==$s)|((.config_files[0].accept // [])|join(" "))' "$_CFG_CATALOG" 2>/dev/null || true)"
    if [ -z "$_tp" ] || [ "$_tp" = "null" ]; then
      log "WARN: '${_slug}' declares config_files but has no target_path — skipping"; continue
    fi

    # Descriptor (root:600) — the single on-box source of truth read by both
    # sb-config-place (validation) and sb-config-reconcile (apply).
    _desc="${_CFG_COMP_DIR}/${_slug}.conf"
    {
      echo "slug=${_slug}"
      echo "target_path=${_tp}"
      echo "multiple=${_multi}"
      echo "accept=${_accept}"
      echo "mode=${_mode}"
      echo "helper=${_helper}"
      echo "service=${_service}"
    } > "$_desc" || { log "WARN: could not write descriptor ${_desc} — skipping ${_slug}"; continue; }
    chmod 600 "$_desc" 2>/dev/null || true

    # Watched path + per-instance drop-in supplying the concrete [Path] directive.
    _dropin_dir="${_CFG_UNIT_DIR}/sb-config-watch@${_slug}.path.d"
    mkdir -p "$_dropin_dir" 2>/dev/null || true
    case "$_tp" in
      */)  # directory of profiles (wireguard, openvpn)
        install -d -m 0700 -o root -g root "${_tp%/}" 2>/dev/null || log "WARN: could not create ${_tp}"
        cat > "${_dropin_dir}/path.conf" <<EOF || { log "WARN: could not write watch drop-in for ${_slug} — skipping"; continue; }
# Written by base/19f (SCRUM-1599) — concrete watch path for ${_slug}.
[Path]
PathModified=${_tp}
DirectoryNotEmpty=${_tp}
EOF
        ;;
      *)   # single pinned file (rdp-client)
        install -d -m 0755 "$(dirname -- "$_tp")" 2>/dev/null || log "WARN: could not create $(dirname -- "$_tp")"
        cat > "${_dropin_dir}/path.conf" <<EOF || { log "WARN: could not write watch drop-in for ${_slug} — skipping"; continue; }
# Written by base/19f (SCRUM-1599) — concrete watch path for ${_slug}.
[Path]
PathModified=${_tp}
PathExists=${_tp}
EOF
        ;;
    esac

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "sb-config-watch@${_slug}.path" >/dev/null 2>&1 \
      && log "config: watching ${_tp} for '${_slug}' (boot-apply + on-change)" \
      || log "WARN: could not enable sb-config-watch@${_slug}.path"

    # One deterministic reconcile now (SHA-gated ⇒ a true no-op when nothing changed),
    # so a fresh provision with a profile already at the default path connects on boot
    # even if the path-unit boot trigger has not fired yet.
    if [ -x /usr/local/bin/sb-config-reconcile ]; then
      /usr/local/bin/sb-config-reconcile "$_slug" >/dev/null 2>&1 \
        || log "WARN: initial reconcile for '${_slug}' reported an error (see journal)"
    fi
  done
else
  log "WARN: jq or ${_CFG_CATALOG} unavailable — component config watchers not wired (wrapper still installed)"
fi

unset -f _cfg_slug_runtime 2>/dev/null || true
