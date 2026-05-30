# post-services.sh — variant overlay (sidebutton-mcp-claude-code-extension)
#
# Wait for Chrome to fetch + install the SideButton extension from the Web
# Store and complete the handshake with the SideButton MCP server on :9876.
# Cold-start on a t3a.medium typically completes inside ~90s; allow up to 5
# min before warning.

step "Waiting for browser_connected=true (up to 5 min)"
BROWSER_READY=0
for i in $(seq 1 60); do
  sleep 5
  HEALTH_JSON=$(curl -sf --max-time 3 http://localhost:9876/health 2>/dev/null || echo '{}')
  BROWSER=$(echo "$HEALTH_JSON" | jq -r '.browser_connected // false' 2>/dev/null || echo "false")
  if [ "$BROWSER" = "true" ]; then
    BROWSER_READY=1
    log "browser_connected=true after $((i*5))s"
    break
  fi
  if [ $((i % 6)) -eq 0 ]; then
    log "  still waiting... ($((i*5))s elapsed, browser_connected=${BROWSER})"
  fi
done
if [ "$BROWSER_READY" != "1" ]; then
  log "WARN: browser_connected did not become true within 5 min."
  log "  Check 'chrome://policy' in an RDP session — ExtensionInstallForcelist must list ${SIDEBUTTON_EXT_ID:-odaefhmdmgijnhdbkfagnlnmobphgkij}."
  log "  If the policy is present, restart chrome.service or reboot the VM to retry the Web Store fetch."
fi
