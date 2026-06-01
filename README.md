# sidebutton/agent-runners

Install scripts for the SideButton agent VM, split into a thin bootstrapper, a shared `base/` set of step scripts, and per-variant overlays.

Production agents are provisioned by piping `https://sidebutton.com/install.sh` to bash — that thin bootstrapper resolves `AGENT_RUNNER` + `RUNNERS_REF`, downloads this repo at the requested ref, and hands off to `base/run.sh`. The bootstrapper plus this repo replace the single monolithic installer that previously lived at `website/public/install.sh`.

## Variants

| Name | Default? | Description |
|------|----------|-------------|
| `sidebutton-mcp-claude-code-extension` | yes | Reproduces today's full install: MCP server, Claude Code CLI, Chrome with the SideButton extension auto-installed via managed policy, and a post-services handshake wait. |
| `sidebutton-mcp-claude-code` | no | Same base, but skips the Chrome managed-policy block and the `browser_connected` handshake wait. Chrome still boots; the extension is not force-installed. |
| `ubuntu-claude-code` | no | Bare Claude Code agent: keeps Ubuntu desktop + Chrome + Claude Code but **drops** the SideButton MCP server, the Chrome extension, and the knowledge-pack registry. A thin [fleet job client](./fleet-job-client/) takes the SB server's spot on `:9876` and implements the minimal heartbeat/job/status contract the portal expects. |

`variants.json` is the canonical manifest (validated against [`variants.schema.json`](./variants.schema.json)). New variants are added by dropping a folder under `variants/<name>/` (with at least a `manifest.json`), optionally with hook scripts, and adding an entry to `variants.json`.

## Portal display metadata (single source of truth)

This repo is also the single source of truth for what the SideButton portal **displays** for each variant + profile — the portal vendors these files and reads them instead of hardcoding:

- **`variants.json`** carries, per variant: `kind` (`ext` / `noext` / `bare`), a role-centric `display` (name + description) used as the fleet-list fallback for rows with no profile, and a `deps` fingerprint — the components the variant installs and which ones show a live status dot.
- **`profiles.json`** (validated against [`profiles.schema.json`](./profiles.schema.json)) is the product-level catalogue the Create-Agent wizard offers: each profile picks a `runner` variant + `default_roles` + `default_plugins` and a role-centric `name`/`description`. `aliases` maps renamed slugs (e.g. `claude-code-headless` → `swe-native`) so already-provisioned agents keep resolving.
- **`plugins.json`** (validated against [`plugins.schema.json`](./plugins.schema.json)) is the catalogue of installable agent plugins — small packages the SideButton MCP server loads from `~/.sidebutton/plugins/` and exposes as MCP tools. Each entry maps a `slug` → public git `repo` (+ `ref`, `submodules`, `system_deps`). `base/19b-plugins.sh` clones and installs the slugs in `SIDEBUTTON_PLUGINS`; the portal vendors the same file to label the plugin chips it shows per agent.

To change a profile name, description, dep chip, plugin, or add a variant/profile: edit it **here**. The portal refreshes its vendored copy with `pnpm --filter website sync:runners`, and a CI `git diff --exit-code` fails on drift.

### Plugins

Plugins are MCP tools the SideButton server hosts, so they only apply to variants that ship a server (`ext`, `noext`) — never the `bare` variant. At provision time the portal forwards `SIDEBUTTON_PLUGINS` (a profile's `default_plugins` ∪ any provision-request override); `base/19b-plugins.sh` runs after `19-secrets.sh` and ends with a `systemctl restart sidebutton` so the server loads the new plugins together with the now-populated `.agent-env` (e.g. `writing-quality` reads `ANTHROPIC_API_KEY` at runtime). The agent reports its loaded plugins on `GET /health` (`plugins[]`), which is what the portal fleet list + agent detail render.

## Layout

```
agent-runners/
├── install.sh                    # direct entry: dispatches to base/run.sh
├── variants.json                 # variant manifest
├── profiles.json                 # Create-Agent wizard profile catalogue (vendored by portal)
├── plugins.json                  # installable agent-plugin catalogue (vendored by portal)
├── base/                         # shared step scripts (sourced in order)
│   ├── lib.sh                    # log/die/step + run_variant_hook
│   ├── 01-preflight.sh           # env validation, OS detect, apt defaults
│   ├── 02-system.sh              # apt upgrade + essentials
│   ├── 03-gh-cli.sh
│   ├── 04-desktop.sh             # XFCE + xrdp
│   ├── 05-node.sh                # Node 22 + pnpm
│   ├── 06-chrome.sh              # Google Chrome (no managed policy)
│   ├── 07-claude-code.sh
│   ├── 08-sidebutton.sh          # MCP server
│   ├── 09-agent-user.sh          # user, dirs, claude settings, swap
│   ├── 11-polkit.sh
│   ├── 12-workspace.sh           # .agent-env template, bashrc hook
│   ├── 13-knowledge-packs.sh     # default registry
│   ├── 14-claude-stop-hook.sh
│   ├── 15-claude-mcp.sh
│   ├── 16-services-prep.sh       # write systemd units + xrdp config
│   ├── 16b-wallpaper.sh          # SideButton desktop background (copy + xfconf autostart applier)
│   ├── 17-services-start.sh      # daemon-reload, enable, start, chown
│   ├── 18-heartbeat.sh           # portal heartbeat
│   ├── 19-secrets.sh             # pull per-agent secrets
│   ├── 19b-plugins.sh            # install SIDEBUTTON_PLUGINS, restart server
│   ├── 20-mark-installed.sh      # write /etc/sidebutton/installed
│   ├── assets/                   # bundled binaries (wallpaper.png)
│   └── run.sh                    # orchestrator
├── variants/
│   ├── sidebutton-mcp-claude-code-extension/
│   │   ├── manifest.json
│   │   ├── pre-services.sh       # Chrome managed policy
│   │   └── post-services.sh      # browser_connected handshake wait
│   ├── sidebutton-mcp-claude-code/
│   │   └── manifest.json         # base-only; no overlays
│   └── ubuntu-claude-code/
│       ├── manifest.json
│       ├── early-setup.sh        # sets SKIP_SIDEBUTTON_SERVER=1, SKIP_KNOWLEDGE_PACKS=1
│       ├── pre-services.sh       # installs fleet-job-client binary + systemd unit
│       └── post-services.sh      # enables + starts fleet-job-client, waits for /health
└── fleet-job-client/             # Node.js daemon used by the bare (ubuntu-claude-code) variant
    ├── bin/fleet-job-client.mjs
    └── README.md
```

## How a variant plugs in

`base/run.sh` invokes three hook points by name:

1. **`early-setup`** — after `01-preflight.sh` (env validated) and before any install step. Variants use this to declare skip flags (`SKIP_SIDEBUTTON_SERVER`, `SKIP_KNOWLEDGE_PACKS`) that affected base steps check before doing work. Lets a variant short-circuit shared install steps without duplicating their code (used by `ubuntu-claude-code`).
2. **`pre-services`** — after `16-services-prep.sh` (unit files written) and before `17-services-start.sh` (systemctl start). Variants use this to write extra configuration that must be in place before services boot, e.g. Chrome's managed policy for the extension force-install, or installing a replacement daemon binary + unit (fleet-job-client).
3. **`post-services`** — after `17-services-start.sh`, before `18-heartbeat.sh`. Variants use this to wait for services to converge on a desired state, e.g. waiting for the SideButton extension's `browser_connected` handshake or for the fleet job client's `/health` to respond.

A hook is a regular bash file at `variants/<name>/<hook>.sh`. It runs in the same shell as `base/run.sh`, so `log`/`die`/`step`/`AGENT_*`/`APT_OPTS`/etc. are already in scope. If a variant doesn't need a hook, simply omit the file.

### Skip flags consumed by base steps

| Flag | Effect |
|---|---|
| `SKIP_SIDEBUTTON_SERVER=1` | Drops `08-sidebutton.sh` (npm install), the `sidebutton.service` unit in `16`, the enable/start lines in `17`, the `claude mcp add sidebutton` call in `15`, and reports `not-installed` instead of `unknown` for `dependency_versions.sidebutton` in `18`. |
| `SKIP_KNOWLEDGE_PACKS=1` | Drops `13-knowledge-packs.sh`. |

## Env vars consumed

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `AGENT_TOKEN` | yes | — | Bootstrap token from `/portal/agents` |
| `AGENT_NAME` | yes | — | Unique fleet identifier |
| `AGENT_ROLE` | no | `se` | One of `se`, `qa`, `sd` |
| `AGENT_RUNNER` | no | `sidebutton-mcp-claude-code-extension` | Variant key under `variants/` |
| `RUNNERS_REF` | no | `main` | Git ref the bootstrapper downloads this repo at |
| `PORTAL_URL` | no | `https://sidebutton.com` | Portal base URL |
| `AGENT_PASSWORD` | no | random | Initial RDP password (overwritten by portal-provided secret) |
| `SIDEBUTTON_DEFAULT_REGISTRY` | no | — | Self-hosted/private knowledge-pack registry; falls back to `sidebutton install agents` when unset |
| `SIDEBUTTON_PLUGINS` | no | — | Comma-separated plugin slugs (`plugins.json`) to install via `19b-plugins.sh`; forwarded by the portal from the profile's `default_plugins` ∪ provision override. No-op on the `bare` variant. |

## Idempotency

`/etc/sidebutton/installed` is written by `20-mark-installed.sh` on success. The thin bootstrapper short-circuits with a service-health summary when this marker exists; remove the marker to force a reinstall.

## License

[MIT](./LICENSE)
