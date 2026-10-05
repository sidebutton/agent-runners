# 16b-wallpaper.sh — the Kadmo-branded desktop wallpaper.
#
# The image ships bundled in agent-runners (base/assets/wallpaper.png; its source is
# base/assets/wallpaper.html) and is copied into place here — no per-install network fetch. If the
# bundled asset is somehow absent (partial tarball), fall back to downloading it from the portal.
#
# xfdesktop assigns the backdrop's monitor name dynamically (it varies on a
# headless Xvfb display), so rather than hard-code a name we drop an XFCE
# autostart entry that enumerates the live backdrop properties and applies the
# image from *inside* the session — where DISPLAY and the session D-Bus are
# already correct. It runs when 17-services-start brings the session up (so the
# brand lands during install) and again on every reboot / RDP relogin.
#
# REFRESH-SAFE (listed in refresh-manifest.txt): it only copies the image and rewrites the applier and the
# autostart entry, all idempotent, so a new image reaches live agents through `sudo sb-self-update`. On a
# live box the XFCE session is already up and its autostart has run, so after the copy the applier is run
# once more INSIDE that session — its DISPLAY and D-Bus address read from the running xfce4-session — so
# the desktop changes without a relogin. At provision there is no session yet and autostart does it.
# The installed names (sidebutton-wallpaper.png, sidebutton-set-wallpaper.sh, the autostart entry) stay as
# they were so no live box is left with a stale copy under an old name.

step "Step 16b/16: Kadmo desktop wallpaper"

WALLPAPER_SRC="${BASE_DIR}/assets/wallpaper.png"
WALLPAPER_DEST="/usr/share/backgrounds/sidebutton-wallpaper.png"

mkdir -p "$(dirname "$WALLPAPER_DEST")"
if [ -f "$WALLPAPER_SRC" ]; then
  if [ -f "$WALLPAPER_DEST" ] && cmp -s "$WALLPAPER_SRC" "$WALLPAPER_DEST"; then
    log "wallpaper unchanged"
  else
    install -m 0644 "$WALLPAPER_SRC" "$WALLPAPER_DEST"
    log "wallpaper copied from bundled asset"
  fi
else
  PORTAL_URL="${PORTAL_URL:-https://sidebutton.com}"
  log "bundled wallpaper missing — downloading from ${PORTAL_URL}/sidebutton-wallpaper.png"
  curl -fsSL "${PORTAL_URL}/sidebutton-wallpaper.png" -o "$WALLPAPER_DEST" \
    || log "WARN: wallpaper download failed — desktop keeps the XFCE default"
fi

if [ -f "$WALLPAPER_DEST" ]; then
  # In-session applier — runs from XFCE autostart, so DISPLAY/D-Bus are correct.
  cat > /usr/local/bin/sidebutton-set-wallpaper.sh <<'WPEOF'
#!/usr/bin/env bash
# Apply the agent desktop wallpaper to every XFCE backdrop. Idempotent; waits for
# xfdesktop to register its backdrop properties (up to ~15s) before setting.
IMG="/usr/share/backgrounds/sidebutton-wallpaper.png"
[ -f "$IMG" ] || exit 0
command -v xfconf-query >/dev/null 2>&1 || exit 0
PROPS=()
for _ in $(seq 1 15); do
  mapfile -t PROPS < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/last-image$')
  [ "${#PROPS[@]}" -gt 0 ] && break
  sleep 1
done
set_one() {
  local last="$1" style="${1%/last-image}/image-style"
  xfconf-query -c xfce4-desktop -p "$last" -s "$IMG" 2>/dev/null \
    || xfconf-query -c xfce4-desktop -p "$last" -n -t string -s "$IMG" 2>/dev/null || true
  # image-style 5 = "Zoomed" (fills the screen, preserves aspect)
  xfconf-query -c xfce4-desktop -p "$style" -s 5 2>/dev/null \
    || xfconf-query -c xfce4-desktop -p "$style" -n -t int -s 5 2>/dev/null || true
}
if [ "${#PROPS[@]}" -eq 0 ]; then
  set_one /backdrop/screen0/monitor0/workspace0/last-image
else
  for P in "${PROPS[@]}"; do set_one "$P"; done
fi
xfdesktop --reload 2>/dev/null || true
WPEOF
  chmod +x /usr/local/bin/sidebutton-set-wallpaper.sh

  # XFCE autostart entry for the agent user.
  install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.config/autostart"
  cat > "${AGENT_HOME}/.config/autostart/sidebutton-wallpaper.desktop" <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Agent Wallpaper
Comment=Apply the Kadmo-branded desktop background
Exec=/usr/local/bin/sidebutton-set-wallpaper.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOPEOF
  chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.config/autostart/sidebutton-wallpaper.desktop"

  # A live box: apply now, inside the running session (see the header).
  _xfce_pid="$(pgrep -u "${AGENT_USER}" -x xfce4-session 2>/dev/null | head -n 1 || true)"
  if [ -n "$_xfce_pid" ] && [ -r "/proc/${_xfce_pid}/environ" ]; then
    _xfce_bus="$(tr '\0' '\n' < "/proc/${_xfce_pid}/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n 1 || true)"
    _xfce_display="$(tr '\0' '\n' < "/proc/${_xfce_pid}/environ" | sed -n 's/^DISPLAY=//p' | head -n 1 || true)"
    if [ -n "$_xfce_bus" ]; then
      timeout 30 runuser -u "${AGENT_USER}" -- env HOME="${AGENT_HOME}" DISPLAY="${_xfce_display:-:10}" \
        DBUS_SESSION_BUS_ADDRESS="$_xfce_bus" /usr/local/bin/sidebutton-set-wallpaper.sh >/dev/null 2>&1 \
        && log "wallpaper applied in the running session" \
        || log "WARN: wallpaper not applied in the running session (it applies at the next login)"
    fi
  fi

  log "wallpaper installed: ${WALLPAPER_DEST} (applied in-session via autostart)"
fi
