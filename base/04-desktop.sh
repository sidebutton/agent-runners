# 04-desktop.sh — XFCE desktop + xrdp.

step "Step 4/16: XFCE desktop + xrdp"
apt-get install "${APT_OPTS[@]}" xfce4 xfce4-goodies xfce4-terminal dbus-x11 xrdp x11vnc xvfb

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
