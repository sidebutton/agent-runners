# 16-services-prep.sh — write systemd unit files + patch xrdp config.
# Does NOT start anything; the variant pre-services hook gets a chance to
# write extra config (e.g. Chrome managed policy) before services-start.sh.

step "Step 16/16: Systemd services (xvfb, xfce-session, x11vnc, chrome, sidebutton)"

cat > /etc/systemd/system/xvfb.service <<'EOF'
[Unit]
Description=Virtual X Framebuffer for Agent Display
After=network.target
Before=xfce-session.service

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :10 -screen 0 1920x1080x24 -ac
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/xfce-session.service <<'EOF'
[Unit]
Description=XFCE Desktop Session on Virtual Display
After=xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=agent
Environment=DISPLAY=:10
ExecStart=/usr/bin/dbus-launch --exit-with-session startxfce4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/x11vnc.service <<'EOF'
[Unit]
Description=x11vnc VNC Server (shares agent display)
After=xfce-session.service
Requires=xvfb.service

[Service]
Type=simple
User=agent
Environment=DISPLAY=:10
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/x11vnc -display :10 -forever -shared -nopw -rfbport 5910 -noxdamage -o /home/agent/.x11vnc.log
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Chrome.service ordering depends on whether sidebutton.service exists.
# Variants that skip the SB server (SKIP_SIDEBUTTON_SERVER=1) drop the After=
# clause so Chrome can boot without waiting for a unit that will never start.
if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  CHROME_AFTER='After=xfce-session.service'
else
  CHROME_AFTER='After=xfce-session.service sidebutton.service'
fi

cat > /etc/systemd/system/chrome.service <<EOF
[Unit]
Description=Chrome Browser with SideButton Extension
${CHROME_AFTER}
Requires=xvfb.service

[Service]
Type=simple
User=agent
Environment=DISPLAY=:10
ExecStartPre=/bin/bash -c 'rm -f /home/agent/.config/google-chrome/Singleton*'
ExecStart=/opt/google/chrome/chrome \\
  --no-first-run \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --noerrdialogs \\
  --disable-features=InfiniteSessionRestore \\
  --profile-directory=Default \\
  https://sidebutton.com
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

if [ "${SKIP_SIDEBUTTON_SERVER:-}" = "1" ]; then
  rm -f /etc/systemd/system/sidebutton.service
  log "sidebutton.service unit not written (SKIP_SIDEBUTTON_SERVER=1)"
else
  cat > /etc/systemd/system/sidebutton.service <<'EOF'
[Unit]
Description=SideButton MCP Server
After=network.target xfce-session.service
Requires=xvfb.service

[Service]
Type=simple
User=agent
WorkingDirectory=/home/agent/workspace
EnvironmentFile=/home/agent/.agent-env
Environment=DISPLAY=:10
ExecStart=/usr/bin/sidebutton serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

# Point xrdp at the shared VNC display (so RDP shows the same session
# Chrome is running on — not a separate empty one).
if [ -f /etc/xrdp/xrdp.ini ]; then
  cp -n /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
  # Define a dedicated session that proxies RDP into the shared x11vnc display
  # (:10 → 127.0.0.1:5910), then autorun it. Use a UNIQUE section name, NOT the
  # stock [vnc-any]: that section ships in Ubuntu's xrdp with ip=ask/port=ask5900,
  # and appending "[vnc-any] only if absent" never fired (it always exists), so
  # RDP stayed pointed at the wrong VNC and died with "Error connecting to user
  # session". A unique name makes append-if-absent correct + idempotent and never
  # touches the stock section.
  if ! grep -q '^\[agent-desktop\]' /etc/xrdp/xrdp.ini; then
    cat >> /etc/xrdp/xrdp.ini <<'EOF'

[agent-desktop]
name=Agent Desktop
lib=libvnc.so
ip=127.0.0.1
port=5910
username=na
password=na
EOF
  fi
  sed -i 's/^autorun=.*/autorun=agent-desktop/' /etc/xrdp/xrdp.ini || true
fi
if [ -f /etc/xrdp/sesman.ini ]; then
  sed -i 's/^KillDisconnected=true/KillDisconnected=false/' /etc/xrdp/sesman.ini || true
fi
