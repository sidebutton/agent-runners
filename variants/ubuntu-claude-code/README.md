# ubuntu-claude-code (bare)

The third runner variant. Keeps everything Claude Code needs to drive a real
browser (Ubuntu desktop, XFCE, x11vnc, Chrome) but drops the SideButton
runtime: no MCP server, no Chrome extension, no knowledge-pack registry.

| Component | This variant | `sidebutton-mcp-claude-code` | `sidebutton-mcp-claude-code-extension` |
|---|---|---|---|
| Ubuntu desktop + Chrome | yes | yes | yes |
| Claude Code CLI | yes | yes | yes |
| SideButton MCP server | **no** | yes | yes |
| SideButton Chrome extension | no | no | yes |
| Knowledge-pack registry | **no** | yes | yes |
| Fleet job client on :9876 | **yes** | no (SB server takes :9876) | no (SB server takes :9876) |

## Why a fleet job client

The portal's Temporal dispatch reaches every agent the same way today:
`POST http://<agent-ip>:9876/api/workflows/<id>/run` plus polling against
`/health`, `/api/running-workflows`, and `/api/runs/<id>` (see
`website/temporal/src/activities/agent.ts`). The fleet job client is a tiny
Node.js HTTP server that exposes the same surface so a bare agent can be
dispatched-to without any portal changes. It also fires periodic heartbeats
(`POST /api/agents/heartbeat`) so the agent stays flagged online without
relying on the SB server's heartbeat cadence.

When dispatched, the client spawns `claude --dangerously-skip-permissions -p -`
with the prompt built from `params.hint` (falling back to a generic
"run workflow X against ticket Y" prompt). The Claude Code Stop hook (shared
across all variants — see `base/14-claude-stop-hook.sh`) handles usage
reporting unchanged, because it only needs `job-context.json` + an
`AGENT_TOKEN` + `AGENT_NAME`, all of which the bare variant still produces.

## Hooks

| Hook | What it does |
|---|---|
| `early-setup` | Exports `SKIP_SIDEBUTTON_SERVER=1` + `SKIP_KNOWLEDGE_PACKS=1` so base steps 08, 13, 15, 16, 17, 18, 19d short-circuit the SB-specific work without duplicating their code. |
| `pre-services` | Installs `fleet-job-client.mjs` to `/usr/local/bin/` and writes the systemd unit. Must run before `17-services-start.sh` so chrome.service doesn't try to `After=sidebutton.service` (the unit doesn't exist on this variant). |
| `post-services` | Enables + starts `fleet-job-client.service` and waits up to 60s for `/health` on :9876. |

## Profile

This variant backs the **SWE Bare** profile in the portal
(`website/src/lib/cloud/profiles.ts`): `runner: 'ubuntu-claude-code'`,
`default_roles: ['se']`. Used to benchmark raw Claude Code against the
extension/native variants (PLAN workstream F).
