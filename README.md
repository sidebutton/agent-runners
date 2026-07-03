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
| `claude-code` | runtime | — | Claude Code agentic CLI — the default agent runtime (base always installs it; no `chip` — the portal hardcodes a lead "Claude Code" chip) |
| `claude-code-router` | runtime | `claude-code` | CCR proxy on `127.0.0.1:3456` routing Claude Code to a configured provider via `ANTHROPIC_BASE_URL` in `~/.agent-env` |
| `chrome` | runtime | — | Chrome browser |
| `sidebutton-server` | runtime | — | MCP server on :9876 — **unlocks dispatch + capabilities** |
| `sidebutton-extension` | runtime | `chrome`, `sidebutton-server` | Chrome managed-policy force-install + handshake wait |
| `knowledge-packs` | packs | `sidebutton-server` | universal `agents` ops pack + account registry |
| `dotnet9` | toolchain | — | .NET 9 SDK |
| `docker` | toolchain | — | Docker engine (+ agent in `docker` group) |
| `postgres-client` | toolchain | — | `psql` |
| `openvpn` | toolchain | — | OpenVPN client + `sb-vpn-connect` helper; auto-consumes `.ovpn` dropped at `/etc/sidebutton/config/openvpn/` (`config_files`) — see [`docs/OPENVPN.md`](./docs/OPENVPN.md) |
| `wireguard` | toolchain | — | WireGuard client + `sb-wg-connect` helper; split-tunnel; auto-consumes `.conf` dropped at `/etc/sidebutton/config/wireguard/` (`config_files`) — see [`docs/WIREGUARD.md`](./docs/WIREGUARD.md) |
| `rdp-client` | toolchain | — | FreeRDP (`xfreerdp`) + `sb-rdp-connect` helper; renders an outbound RDP session as a fixed-geometry window on `:10` for computer-use; auto-enables when `/etc/sidebutton/rdp.env` lands (`config_files`) — see [`docs/RDP.md`](./docs/RDP.md) |

`base/components.sh` resolves `AGENT_COMPONENTS` (comma- or space-separated) into
the `has_component` helper + the `SKIP_*` / `INSTALL_*` gates the step scripts
read, and enforces `requires` defensively. Component
install logic lives under `base/components/<slug>/` (`install.sh` for
runtime/toolchain installs; `pre-services.sh` / `post-services.sh` for lifecycle
phases — e.g. the extension's managed-policy + handshake).

`components.json` is validated against
[`components.schema.json`](./components.schema.json), enforced by
[`base/tests/test-components-schema.sh`](./base/tests) (see **Testing / CI** below).

A component may declare **`config_files`** — runtime config it consumes from a default
path on the agent (e.g. a WireGuard `.conf`). `base/19f-component-config.sh` installs a
systemd path-unit watcher per declared path + the privileged `sb-config-place` wrapper
(narrow sudoers), so a file dropped at `target_path` is applied automatically (boot-time
+ on change) and torn down on removal — manual SSH placement and portal delivery
converge. See [`base/tests/test-component-config.sh`](./base/tests) and the per-component
docs (SCRUM-1599).

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
| **SideButton SWE Full Stack** (default) | `claude-code, chrome, sidebutton-server, sidebutton-extension, knowledge-packs` | se, qa, sd, pm |
| **SideButton SWE .NET** | Full Stack + `dotnet9` | se, qa, sd, pm |
| **SideButton SWE Native** | `claude-code, chrome, sidebutton-server, knowledge-packs` | se, qa |

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
│   ├── lib-refresh.sh            # shared change-gated base-artifact refresh (sb-self-update + agent-redeploy.sh)
│   ├── refresh-manifest.txt      # base steps safe to re-run on a live agent (drives the refresh)
│   ├── components.sh             # resolve AGENT_COMPONENTS → has_component + gates
│   ├── 01-preflight.sh … 20-mark-installed.sh   # shared steps (sourced in order)
│   ├── 06-chrome.sh              # gated on INSTALL_CHROME
│   ├── 08-sidebutton.sh          # SB server (gated) + installs the sb-self-update wrapper (all agents)
│   ├── 16-services-prep.sh       # chrome/sidebutton units written conditionally
│   ├── 18b-heartbeat-timer.sh    # recurring online beat when serverless
│   ├── 19e-session-reaper.sh     # close Claude Code sessions idle >1h after finish
│   ├── components/               # per-component install + lifecycle scripts
│   │   ├── dotnet9/install.sh
│   │   ├── docker/install.sh
│   │   ├── postgres-client/install.sh
│   │   ├── openvpn/{install.sh,sb-vpn-connect}
│   │   ├── wireguard/{install.sh,sb-wg-connect}
│   │   ├── rdp-client/{install.sh,sb-rdp-connect}
│   │   └── sidebutton-extension/{pre,post}-services.sh
│   ├── assets/                   # wallpaper.png, report-health-snapshot.sh, sb-registry-sync.sh, sb-self-update.sh
│   ├── tests/                    # pure bash+jq regression guards + run-all.sh runner
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
6. Register + heartbeat (+ recurring timer), secrets, plugins, health reporter
   (desktop screenshot + a per-session Claude terminal-window crop via `xdotool`),
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

## Self-update (the fleet path)

Existing agents keep themselves current via **`sb-self-update`** — a tiny
root-owned wrapper installed by `base/08` and run fleet-wide by the
`agent_pull_repos` ops job through a narrow NOPASSWD sudoers rule scoped to *only*
that wrapper (the agent's single privileged action). It does two idempotent,
**change-gated** things:

1. Upgrade the global `sidebutton` CLI/server npm package, restarting the service
   **only** when the version changed (self-gated on `command -v sidebutton`, so a
   no-op on serverless variants).
2. **Refresh base artifacts** — re-download `agent-runners@<ref>` and re-run the
   refresh-safe base steps (`base/refresh-manifest.txt`) + re-merge the Claude
   hooks block over `~/.claude/settings.json`, so step-script / hook changes reach
   the fleet without an operator SSH. A fingerprint over the deployed artifacts is
   compared against `/etc/sidebutton/updated`; a routine tick with nothing new
   upstream is a true no-op (no rewrite, no restart). The shared apply logic lives
   in `base/lib-refresh.sh`, which the operator break-glass `agent-redeploy.sh`
   (in the-assistant) also sources from the downloaded tree, so the two paths
   can't drift.

The manifest is the source of truth for which steps are safe to re-run on a live
box — token-rotating / re-registering / OS-install steps are deliberately
excluded. Add new refresh-safe steps there so they reach existing agents.

**Drift visibility:** the heartbeat (`base/18`, and the serverless `18b` timer)
reports the *effective* `runners_ref` + a `base_artifacts_sha` from the markers
(`/etc/sidebutton/updated`, else the provision-time `/etc/sidebutton/installed`),
so the portal can show what each agent is actually running.

## Idempotency

`/etc/sidebutton/installed` is written by `20-mark-installed.sh` on success (now
including a `base_artifacts_sha` fingerprint + `runners_repo`). The bootstrapper
short-circuits with a service-health summary when present; remove the marker to
force a reinstall. `/etc/sidebutton/updated` records the effective ref +
fingerprint after each `sb-self-update` base-artifact refresh.

## Testing / CI

`base/tests/` holds pure **bash + jq** regression guards (no bats, no network) — each
runnable directly (`bash base/tests/<name>.sh`) and together via the runner:

```
bash base/tests/run-all.sh          # discover + run the suite (CI mode); SUITE GREEN on success
bash base/tests/run-all.sh --all    # also run host-dependent guards (only green on a clean box)
```

`run-all.sh` auto-discovers every `test-*.sh` (a new guard needs no wiring), prints a
per-file PASS/FAIL + tally, and exits non-zero on any failure. It skips the guards
listed in [`base/tests/ci-exclude.txt`](./base/tests/ci-exclude.txt) — currently only
`test-sb-self-update.sh`, which false-fails on a host that already has a global
`sidebutton` CLI (every provisioned agent VM); each exclusion carries its reason.

Component-model coverage (the catalog ↔ schema ↔ on-disk ↔ `run.sh` wiring contract):

| Guard | Asserts |
|---|---|
| `test-components-schema.sh` | `components.json` is valid against `components.schema.json` (structure, enums, slug pattern, `additionalProperties:false`) + unique slugs + every `requires[]` resolves |
| `test-component-resolution.sh` | every `base/components/<dir>` is a catalog slug **and** wired into `run.sh`; every non-base-installed slug has a dir; the base-installed allowlist (`chrome`/`sidebutton-server`/`knowledge-packs`) is justified by its `06`/`08`/`13` step; all `*.sh` parse |
| `test-default-install-parity.sh` | default / empty / back-compat + every profile resolves to a byte-identical gate vector vs a committed snapshot (re-bless: `BLESS=1 bash …`) |
| `test-claude-code-*` / `test-claude-code-router-component.sh` | the claude-code + CCR components' catalog shape, install dir, and `run.sh` wiring |
| `test-component-config.sh` | `config_files` catalog + schema contract, `19f` wiring (run.sh order + refresh-manifest), asset parse, `sb-config-place` path-confinement (traversal rejected), `sb-config-reconcile` apply/SHA-gate/teardown (SCRUM-1599) |

CI (`.github/workflows/tests.yml`) runs `run-all.sh` on every push to `main` + PR
(`ubuntu-latest` + `jq`).

## License

[MIT](./LICENSE)
