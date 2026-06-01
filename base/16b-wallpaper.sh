# 16b-wallpaper.sh — SideButton-branded desktop wallpaper.
#
# The image ships bundled in agent-runners (base/assets/wallpaper.png) and is
# copied into place here — no per-install network fetch. If the bundled asset is
# somehow absent (partial tarball), fall back to downloading it from the portal.
#
# xfdesktop assigns the backdrop's monitor name dynamically (it varies on a
# headless Xvfb display), so rather than hard-code a name we drop an XFCE
# autostart entry that enumerates the live backdrop properties and applies the
# image from *inside* the session — where DISPLAY and the session D-Bus are
# already correct. It runs when 17-services-start brings the session up (so the
# brand lands during install) and again on every reboot / RDP relogin.

step "Step 16b/16: SideButton desktop wallpaper"

WALLPAPER_SRC="${BASE_DIR}/assets/wallpaper.png"
WALLPAPER_DEST="/usr/share/backgrounds/sidebutton-wallpaper.png"

mkdir -p "$(dirname "$WALLPAPER_DEST")"
if [ -f "$WALLPAPER_SRC" ]; then
  install -m 0644 "$WALLPAPER_SRC" "$WALLPAPER_DEST"
  log "wallpaper copied from bundled asset"
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
# Apply the SideButton wallpaper to every XFCE backdrop. Idempotent; waits for
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
Name=SideButton Wallpaper
Comment=Apply the SideButton-branded desktop background
Exec=/usr/local/bin/sidebutton-set-wallpaper.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOPEOF
  chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.config/autostart/sidebutton-wallpaper.desktop"

  log "wallpaper installed: ${WALLPAPER_DEST} (applied in-session via autostart)"
fi
