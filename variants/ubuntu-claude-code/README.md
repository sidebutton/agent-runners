# ubuntu-claude-code (base runner)

The **single** runner variant. The old `swe-full-stack` / `swe-native` / `swe-bare`
variant matrix is gone — there is now one base + a catalog of optional
**components** (see [`../../components.json`](../../components.json) and
[`../../docs/COMPONENTS.md`](../../docs/COMPONENTS.md)).

## What the base always installs

| Concern | Notes |
|---|---|
| Ubuntu desktop + RDP/VNC | XFCE, `xrdp`, `x11vnc`, `Xvfb` — view/operate via RDP |
| Node 22 + Claude Code CLI | run `claude` manually over RDP |
| `~/.agent-env` + git credential helpers + `~/workspace` | clone assigned workspace repos without the server |
| Per-agent secrets fetch | `GH_TOKEN`, `ANTHROPIC_API_KEY`, `JIRA_*`, … |
| Register + recurring heartbeat | shows online in the portal even with no server |

A base-only agent is **not dispatchable** (no `sidebutton-server` ⇒ no
capabilities) — it is a manual / RDP agent.

## Components layered on top (selected via `AGENT_COMPONENTS`)

`chrome`, `sidebutton-server` (unlocks dispatch + capabilities),
`sidebutton-extension` (requires chrome + server), `knowledge-packs`,
`screen-record` / `writing-quality` (MCP plugins), and toolchains `dotnet9`,
`docker`, `postgres-client`.

Profiles ([`../../profiles.json`](../../profiles.json)) are named presets of
these components that the Create-Agent wizard pre-checks; the user may uncheck or
add any component.

## Hooks

None. The variant hook mechanism is retained in `base/run.sh`
(`run_variant_hook`) but this base variant ships no hooks; component lifecycle
scripts (e.g. `base/components/sidebutton-extension/{pre,post}-services.sh`) are
invoked by `base/run.sh` from the resolved component set.
