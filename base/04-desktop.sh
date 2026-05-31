# 04-desktop.sh — XFCE desktop + xrdp.

step "Step 4/16: XFCE desktop + xrdp"
# The XFCE dependency closure pulls usbmuxd (via libimobiledevice6), whose
# preinst runs adduser→chfn to set the usbmux user's GECOS. On Hetzner's Ubuntu
# cloud image that chfn call fails once (`chfn ... returned error code 1` →
# preinst exit 82), which aborts the whole apt run under `set -e` and leaves the
# install dead at step 4 (no server, no heartbeat). The usbmux user *is* created
# before chfn fails, so `dpkg --configure -a` + a retry completes cleanly
# (verified on a stuck fsn1 VM). The retry only runs on failure, so AWS — where
# the first install succeeds — is unaffected. Also hardens the large desktop
# install against any single-package maintainer-script hiccup.
DESKTOP_PKGS=(xfce4 xfce4-goodies xfce4-terminal dbus-x11 xrdp x11vnc xvfb)
if ! apt-get install "${APT_OPTS[@]}" "${DESKTOP_PKGS[@]}"; then
  log "WARN: desktop install failed (likely usbmuxd preinst/chfn); recovering + retrying"
  dpkg --configure -a || true
  apt-get install -f "${APT_OPTS[@]}" || true
  apt-get install "${APT_OPTS[@]}" "${DESKTOP_PKGS[@]}"
fi

cat > /etc/xrdp/startwm.sh <<'XRDPEOF'
#!/bin/sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
XRDPEOF
chmod +x /etc/xrdp/startwm.sh

adduser xrdp ssl-cert 2>/dev/null || true
systemctl enable xrdp >/dev/null
systemctl restart xrdp
