# sidebutton-mcp-claude-code

Same base as `sidebutton-mcp-claude-code-extension`, with these intentional drops:

- **No Chrome managed policy.** `/etc/opt/chrome/policies/managed/sidebutton.json` is not written, so Chrome does not auto-install the SideButton extension. Chrome still boots; the SideButton MCP server still runs on `:9876`, but `browser_connected` will stay `false`.
- **No browser_connected handshake wait.** The installer does not block waiting for the extension to phone home — there's nothing to wait for.

When to use this variant: benchmarking Claude Code's native tools against the SideButton browser bridge, or fleets that drive automation through other means.

This directory contains only a manifest because the variant is "base minus the default's overlays" — there are no overlay scripts to run.
