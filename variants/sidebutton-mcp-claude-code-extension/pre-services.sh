# pre-services.sh — variant overlay (sidebutton-mcp-claude-code-extension)
#
# Force-install the SideButton Chrome extension via managed policy. The Web
# Store listing is public and the extension ID is stable:
#   https://chromewebstore.google.com/detail/sidebutton/odaefhmdmgijnhdbkfagnlnmobphgkij
# This MUST be in place BEFORE chrome.service first starts so the policy is
# read during Chrome's initial profile creation. Without this, the extension
# never auto-installs and browser_connected stays false.

SIDEBUTTON_EXT_ID="odaefhmdmgijnhdbkfagnlnmobphgkij"
SIDEBUTTON_UPDATE_URL="https://clients2.google.com/service/update2/crx"

mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/sidebutton.json <<EOF
{
  "ExtensionInstallForcelist": [
    "${SIDEBUTTON_EXT_ID};${SIDEBUTTON_UPDATE_URL}"
  ]
}
EOF
chmod 644 /etc/opt/chrome/policies/managed/sidebutton.json

# Mirror to the chromium policy path for the arm64 chromium-browser fallback.
mkdir -p /etc/chromium/policies/managed
cp /etc/opt/chrome/policies/managed/sidebutton.json /etc/chromium/policies/managed/sidebutton.json
log "policy: ExtensionInstallForcelist installed (${SIDEBUTTON_EXT_ID})"

export SIDEBUTTON_EXT_ID
