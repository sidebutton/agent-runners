# sidebutton/agent-runners

Install scripts for the SideButton agent VM: a thin bootstrapper, a shared
`base/` set of step scripts, and a catalog of optional **components**.

Production agents are provisioned by piping `https://sidebutton.com/install.sh`
to bash — that thin bootstrapper resolves `AGENT_RUNNER` + `AGENT_COMPONENTS` +
`RUNNERS_REF`, downloads this repo at the requested ref, and hands off to
`base/run.sh`.

## Model: one base + optional components

There is a **single base runner**, `ubuntu-claude-code` (named after its deps:
Ubuntu desktop + Claude Code). The base installs a complete, **dispatch-free**
agent — RDP in and run `claude` manually, clone the assigned workspace repos
(git credential helpers are pre-wired). Everything else is an **optional
component**, selected per-agent via the `AGENT_COMPONENTS` env list.

See [`docs/COMPONENTS.md`](./docs/COMPONENTS.md) for the full design.

### Base (always installed)

XFCE desktop + `xrdp`/`x11vnc`/`Xvfb`, Node 22, the Claude Code CLI,
`~/.agent-env` + git credential helpers + `~/workspace`, per-agent secrets,
portal registration, and a recurring heartbeat (keeps the agent online even
without the SideButton server). A base-only agent has **no capabilities and is
not dispatchable** — it's a manual / RDP agent.

### Components (`components.json`)

| slug | kind | requires | notes |
|---|---|---|---|
| `chrome` | runtime | — | Chrome browser |
| `sidebutton-server` | runtime | — | MCP server on :9876 — **unlocks dispatch + capabilities** |
| `sidebutton-extension` | runtime | `chrome`, `sidebutton-server` | Chrome managed-policy force-install + handshake wait |
| `knowledge-packs` | packs | `sidebutton-server` | universal `agents` ops pack + account registry |
| `dotnet9` | toolchain | — | .NET 9 SDK |
| `docker` | toolchain | — | Docker engine (+ agent in `docker` group) |
| `postgres-client` | toolchain | — | `psql` |
| `openvpn` | toolchain | — | OpenVPN client + `sb-vpn-connect` helper (.ovpn applied manually post-provision — see [`docs/OPENVPN.md`](./docs/OPENVPN.md)) |

`base/components.sh` resolves `AGENT_COMPONENTS` (comma- or space-separated) into
the `has_component` helper + the `SKIP_*` / `INSTALL_*` gates the step scripts
read, and enforces `requires` defensively. Component
install logic lives under `base/components/<slug>/` (`install.sh` for
runtime/toolchain installs; `pre-services.sh` / `post-services.sh` for lifecycle
phases — e.g. the extension's managed-policy + handshake).

`components.json` is validated against
[`components.schema.json`](./components.schema.json).

### Plugins (`plugins.json`) — separate, role-driven

MCP plugins are Claude-Code-skill-like tools the SideButton server loads (not components). Each entry
carries install detail (`repo`/`ref`/`submodules`/`system_deps`) + `default_roles`; the wizard
pre-checks them **by role** in Step 2 (only when `sidebutton-server` is selected), and the final
selection is sent as `SIDEBUTTON_PLUGINS` and installed by `base/19b-plugins.sh`.

| slug | default_roles | requires |
|---|---|---|
| `screen-record` | `["*"]` (all roles) | `sidebutton-server` |
| `writing-quality` | `["smm"]` | `sidebutton-server` |

`plugins.json` is validated against [`plugins.schema.json`](./plugins.schema.json).

### Profiles (`profiles.json`) — wizard presets

A profile is a named **preset** of components (+ default roles) the Create-Agent
wizard pre-checks; the user may uncheck or add any component.

| Profile | Components | Roles |
|---|---|---|
| **SideButton SWE Full Stack** (default) | `chrome, sidebutton-server, sidebutton-extension, knowledge-packs` | se, qa, sd, pm |
| **SideButton SWE .NET** | Full Stack + `dotnet9` | se, qa, sd, pm |
| **SideButton SWE Native** | `chrome, sidebutton-server, knowledge-packs` | se, qa |

Plugins are selected separately, by role (see Plugins above) — not baked into profile presets.

## Portal display metadata (single source of truth)

The portal vendors these files instead of hardcoding; refresh with
`pnpm --filter website sync:runners`, and a CI `git diff --exit-code` fails on
drift:

- **`components.json`** — component catalog: `kind`, `requires`, dep-`chip`.
- **`profiles.json`** — wizard presets (component sets + roles).
- **`variants.json`** — the single base runner (display fallback + legacy `kind`).
- **`plugins.json`** — the role-driven plugin catalog: install detail (slug → git `repo`) +
  per-plugin `default_roles`, consumed by `base/19b-plugins.sh` via `SIDEBUTTON_PLUGINS`.

## Layout

```
agent-runners/
├── install.sh                    # direct entry: resolves variant dir → base/run.sh
├── components.json               # component catalog (vendored by portal)
├── profiles.json                 # wizard presets (vendored by portal)
├── variants.json                 # single base runner manifest (vendored by portal)
├── plugins.json                  # role-driven plugin catalogue (slug → repo + default_roles)
├── docs/COMPONENTS.md            # component model + implementation plan
├── base/
│   ├── lib.sh                    # log/die/step + run_variant_hook
│   ├── components.sh             # resolve AGENT_COMPONENTS → has_component + gates
│   ├── 01-preflight.sh … 20-mark-installed.sh   # shared steps (sourced in order)
│   ├── 06-chrome.sh              # gated on INSTALL_CHROME
│   ├── 08-sidebutton.sh          # gated on SKIP_SIDEBUTTON_SERVER
│   ├── 16-services-prep.sh       # chrome/sidebutton units written conditionally
│   ├── 18b-heartbeat-timer.sh    # recurring online beat when serverless
│   ├── 19e-session-reaper.sh     # close Claude Code sessions idle >1h after finish
│   ├── components/               # per-component install + lifecycle scripts
│   │   ├── dotnet9/install.sh
│   │   ├── docker/install.sh
│   │   ├── postgres-client/install.sh
│   │   ├── openvpn/{install.sh,sb-vpn-connect}
│   │   └── sidebutton-extension/{pre,post}-services.sh
│   ├── assets/                   # wallpaper.png, report-health-snapshot.sh, sb-registry-sync.sh
│   └── run.sh                    # orchestrator
└── variants/
    └── ubuntu-claude-code/       # the single base variant (manifest + README; no hooks)
```

## How `base/run.sh` works

1. `01-preflight.sh`, then `components.sh` resolves the component set + gates.
2. Install phase: base steps run; gated steps (`06-chrome`, `08-sidebutton`,
   `13-knowledge-packs`, `15-claude-mcp`, `19c-health-report`) honor the gates;
   toolchain components install after the agent user exists (so `docker` can add
   it to the `docker` group).
3. **pre-services**: the `sidebutton-extension` component writes the Chrome
   managed policy (must precede `chrome.service` first start), then
   `run_variant_hook "pre-services"` (no-op for the base variant).
4. `17-services-start.sh` starts the desktop + selected services.
5. **post-services**: the extension component waits for `browser_connected`.
6. Register + heartbeat (+ recurring timer), secrets, plugins, health reporter,
   account registry, stale-session reaper, mark-installed.

The variant hook mechanism (`run_variant_hook`) is retained but the single base
variant ships no hooks — component behaviour is driven from `run.sh`.

### Gates derived from the component set

| Gate | Set when |
|---|---|
| `SKIP_SIDEBUTTON_SERVER=1` | `sidebutton-server` not selected → skips `08`, the `sidebutton.service` unit, `15`, `19c`; reports `sidebutton: not-installed` |
| `SKIP_KNOWLEDGE_PACKS=1` | `knowledge-packs` not selected → skips `13` + `19d` |
| `INSTALL_CHROME=0` | `chrome` not selected → skips `06` + the `chrome.service` unit/start |
| `INSTALL_EXTENSION=1` | `sidebutton-extension` selected → runs the extension component's pre/post-services |

## Env vars consumed

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `AGENT_TOKEN` | yes | — | Bootstrap token from `/portal/agents` |
| `AGENT_NAME` | yes | — | Unique fleet identifier |
| `AGENT_ROLE` | no | `se` | One of `se`, `qa`, `sd` |
| `AGENT_COMPONENTS` | no | — | Comma/space list of component slugs. Unset ⇒ manual base agent (no optional components) |
| `AGENT_RUNNER` | no | `ubuntu-claude-code` | The single base variant |
| `RUNNERS_REF` | no | `main` | Git ref the bootstrapper downloads this repo at |
| `PORTAL_URL` | no | `https://sidebutton.com` | Portal base URL |
| `AGENT_PASSWORD` | no | random | Initial RDP password (overwritten by portal secret) |
| `SIDEBUTTON_DEFAULT_REGISTRY` | no | — | Per-account knowledge-pack registry (git URL); additive on top of the `agents` pack |
| `SIDEBUTTON_DEFAULT_REGISTRY_TOKEN` | no | — | Auth token for a private registry; delivered via the secrets fetch |
| `SIDEBUTTON_PLUGINS` | no | — | Comma plugin slugs (`plugins.json`); selected by the portal per role. Requires `sidebutton-server` |

## No legacy

Old agents are deleted and re-provisioned, so the portal always sends an explicit
`AGENT_COMPONENTS` (+ `SIDEBUTTON_PLUGINS`). `base/components.sh` reads `AGENT_COMPONENTS` only —
unset ⇒ a manual base agent. The old `AGENT_RUNNER`→component-set mapping and profile `aliases` have
been removed.

## Idempotency

`/etc/sidebutton/installed` is written by `20-mark-installed.sh` on success. The
bootstrapper short-circuits with a service-health summary when present; remove
the marker to force a reinstall.

## License

[MIT](./LICENSE)
