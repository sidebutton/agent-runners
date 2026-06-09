# 06-chrome.sh — Google Chrome.
#
# `chrome` is an optional component (INSTALL_CHROME from base/components.sh). It
# is required by `sidebutton-extension` and by Claude-native browsing; a manual
# agent that selects neither can skip it. The extension's managed policy is owned
# by the sidebutton-extension component (pre-services), not this step.

if [ "${INSTALL_CHROME:-1}" != "1" ]; then
  step "Step 6/16: Google Chrome (skipped — chrome component not selected)"
else
  step "Step 6/16: Google Chrome"
  if ! command -v google-chrome-stable >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture)"
    if [ "$arch" = "arm64" ]; then
      log "Chrome unavailable on arm64; installing Chromium"
      apt-get install "${APT_OPTS[@]}" chromium-browser
      ln -sf /usr/bin/chromium-browser /usr/local/bin/google-chrome-stable
    else
      wget -q --timeout=30 --tries=3 -O /tmp/chrome.deb \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_${arch}.deb"
      apt-get install "${APT_OPTS[@]}" /tmp/chrome.deb || apt-get install -f "${APT_OPTS[@]}"
      rm -f /tmp/chrome.deb
    fi
  fi
  log "chrome: $(google-chrome-stable --version)"
fi
