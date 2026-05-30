# sidebutton-mcp-claude-code-extension

The default SideButton agent. Reproduces the install behavior that shipped before the agent-runners split.

Overlays added on top of `base/`:

- **`pre-services.sh`** — writes `/etc/opt/chrome/policies/managed/sidebutton.json` (mirrored to the chromium path) with `ExtensionInstallForcelist` for the SideButton Chrome extension (`odaefhmdmgijnhdbkfagnlnmobphgkij`). Runs after the systemd unit files have been written but before `chrome.service` starts, so Chrome reads the policy on its first profile creation.
- **`post-services.sh`** — polls `http://localhost:9876/health` for `browser_connected=true` for up to 5 minutes. Warns (does not fail) if the handshake never lands; the install still completes so the VM is usable.

Use this variant for any fleet where agents drive a real browser via the SideButton MCP bridge.
