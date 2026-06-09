# components/sidebutton-extension/post-services.sh
#
# Wait for Chrome to fetch + install the SideButton extension from the Web Store
# and complete the handshake with the SideButton MCP server on :9876. Sourced by
# base/run.sh at the post-services phase when `sidebutton-extension` is selected.
#
# The extension is force-installed via managed policy (ExtensionInstallForcelist,
# see pre-services.sh) as a single best-effort fetch when chrome.service first
# starts. Cold-start typically completes inside ~90s. But if that first fetch
# fails (e.g. a transient Web Store hiccup — more likely when several fresh
# instances provision at once and fetch the same CRX simultaneously), Chrome
# will NOT retry for ~5h, far past any provisioning window, leaving the agent at
# browser_connected=false ("no extension"). A chrome.service restart triggers an
# immediate re-fetch that reliably succeeds in ~10s — so on timeout we
# bounce-and-rewait instead of just warning and giving up. (SCRUM-1172)

# Seconds to wait for the (slow) initial Web Store fetch before the first restart.
INITIAL_WAIT_S=90
# Seconds to wait after each restart (a restart recovers in ~10s; allow margin).
RETRY_WAIT_S=60
# How many chrome.service restarts to attempt before warning.
MAX_RESTARTS=3

# Polls /health until browser_connected=true or the time budget runs out.
#   $1 = max seconds to wait. Returns 0 if connected, 1 otherwise.
wait_for_browser() {
  local max_s="$1" waited=0 health browser
  while [ "$waited" -lt "$max_s" ]; do
    sleep 5
    waited=$((waited + 5))
    health=$(curl -sf --max-time 3 http://localhost:9876/health 2>/dev/null || echo '{}')
    browser=$(echo "$health" | jq -r '.browser_connected // false' 2>/dev/null || echo "false")
    [ "$browser" = "true" ] && return 0
    if [ $((waited % 30)) -eq 0 ]; then
      log "  still waiting... (${waited}s this attempt, browser_connected=${browser})"
    fi
  done
  return 1
}

step "Waiting for browser_connected=true (force-install + handshake)"
BROWSER_READY=0
if wait_for_browser "$INITIAL_WAIT_S"; then
  BROWSER_READY=1
  log "browser_connected=true on first boot"
else
  for attempt in $(seq 1 "$MAX_RESTARTS"); do
    log "browser_connected still false — restarting chrome.service to retry Web Store fetch (${attempt}/${MAX_RESTARTS})"
    systemctl restart chrome.service || true
    if wait_for_browser "$RETRY_WAIT_S"; then
      BROWSER_READY=1
      log "browser_connected=true after chrome.service restart #${attempt}"
      break
    fi
  done
fi

if [ "$BROWSER_READY" != "1" ]; then
  log "WARN: browser_connected did not become true after ${MAX_RESTARTS} chrome.service restarts."
  log "  Check 'chrome://policy' in an RDP session — ExtensionInstallForcelist must list ${SIDEBUTTON_EXT_ID:-odaefhmdmgijnhdbkfagnlnmobphgkij}."
  log "  The extension is fetched from the Chrome Web Store at first boot; verify outbound access to clients2.google.com, then reboot the VM."
fi
