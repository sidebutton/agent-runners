# Elixir component (Erlang/OTP + Elixir via mise)

Build and test Elixir / Phoenix repos on a fleet agent. The component pre-bakes
**one** Erlang/OTP + Elixir pair at provision time, bootstraps Hex + rebar3, and
puts the toolchain on the PATH a **dispatched job** actually sees — not just an
RDP shell.

| Pinned in [`base/components/elixir/install.sh`](../base/components/elixir/install.sh) | Value |
|---|---|
| Erlang/OTP | `28.5.0.5` |
| Elixir | `1.20.3-otp-28` |
| mise | `v2026.8.3` |

Bump the constants at the top of `install.sh` deliberately. The Elixir build's
**`-otp-NN` suffix must match the pinned OTP major** — Elixir's precompiled builds
are OTP-major-keyed, and an absent or mismatched suffix silently installs the build
for the *oldest* supported OTP. `base/tests/test-elixir-component.sh` asserts this.

## Pair it with `docker` — `postgres-client` is not enough

Every Phoenix test suite needs a **real Postgres server**. `postgres-client` ships
only `psql` (a client). Select the **`docker`** component alongside `elixir` and run
Postgres as a container (Testcontainers, `docker compose`, or a plain
`docker run postgres`). The wizard cannot enforce this — the component's
`requires[]` is empty on purpose, since a repo with no database does not need it —
so it is stated in the catalog description the wizard renders verbatim.

## Disk

`deps/` + `_build/` run **1–3 GB per app**, before Dialyzer PLTs. Prefer a
**Medium or larger** machine with generous disk. There is currently **no
per-component disk dimension** anywhere in the portal (the AWS root volume is a
fixed 40 GB gp3 and `VmSpec` carries only vcpu/ram/nested_virt), so disk is guidance,
not an enforced floor. A disk-full agent fails in a hard-to-read way — keep an eye
on it when several Elixir repos share one agent.

## Why the toolchain is symlinked into `/usr/local/bin`

`sidebutton.service` runs as `User=agent` with an `EnvironmentFile` and **no**
`Environment=PATH=`, so a dispatched job inherits systemd's default PATH and reads
neither `~/.bashrc` nor `/etc/environment`. A `mise activate` line in `.bashrc`
alone would therefore give a working RDP shell and `mix: command not found` on
**every dispatched job**.

`/usr/local/bin` *is* on systemd's default PATH, so `install.sh` symlinks the mise
shims there (`elixir elixirc mix iex erl erlc escript epmd dialyzer typer`) — the
same trick `dotnet9` uses for `dotnet` and `android-sdk` for `adb`. Two properties
of that link matter:

- **The basename must equal the tool name.** mise dispatches a shim on `argv[0]`;
  a renamed link fails with `<name> is not a valid shim`.
- **Version resolution still happens at exec time**, from the current working
  directory — so the symlinks do *not* freeze the pinned pair (below).

`.bashrc` additionally gets a real `eval "$(mise activate bash)"` for interactive
and RDP shells.

## Per-repo overrides — `.tool-versions`

A repo that pins its own versions keeps them. mise reads asdf-style
`.tool-versions` **natively and by default** (unlike *idiomatic* files such as
`.node-version`, which are off unless `idiomatic_version_file_enable_tools` lists
the tool). Because the shims re-resolve per directory:

```bash
cd ~/workspace/some-phoenix-app   # .tool-versions: elixir 1.20.2-otp-28
mix --version                     # -> Mix 1.20.2, not the pre-baked 1.20.3
```

**Cost of diverging.** A version the agent was not pre-baked with is downloaded on
first use. For Elixir that is seconds. For **Erlang** it depends on whether
builds.hex.pm publishes a precompiled build for this platform:

- **Precompiled available** (`ubuntu-24.04` / `amd64` — what the base runner is):
  a download, a few seconds.
- **Not available**: mise silently falls back to a **kerl source build, 10–20
  minutes**, at job time. The component installs the source-build deps
  (`build-essential`, `autoconf`, `libssl-dev`, `libncurses-dev`) precisely so this
  fallback works rather than fails.

`install.sh` probes the same builds.hex.pm URL mise would use and logs which path
to expect — grep the provision log:

```bash
grep -E 'elixir:|erlang:' /var/log/sidebutton-install.log
```

## Hex + rebar3 are per-Elixir-version

mise's Elixir plugin points `MIX_HOME` at the **Elixir install directory**
(`~/.local/share/mise/installs/elixir/<version>/.mix`) — *not* `~/.mix`. The
provision-time `mix local.hex --force` / `mix local.rebar --force` therefore
bootstrap only the **pre-baked** Elixir. A repo whose `.tool-versions` selects a
different Elixir gets its own empty `MIX_HOME` and re-fetches Hex on first use,
which needs network. If a job fails on a missing Hex, that is the reason:

```bash
mix local.hex --force && mix local.rebar --force
```

Note also that `mix local.rebar` installs a **mix-private** `rebar3` inside
`MIX_HOME`; mise creates no `rebar3` shim, so there is deliberately no
`/usr/local/bin/rebar3`. Use `mix deps.get` / `mix compile`, which find it.

## Dialyzer PLT cache

`install.sh` creates an agent-owned **`~/.cache/dialyzer`**, outside any repo, so
the slow core PLT survives a fresh clone or a branch switch. Repos opt in from
`mix.exs`:

```elixir
def project do
  [
    # …
    dialyzer: [
      plt_local_path: Path.expand("~/.cache/dialyzer"),
      plt_core_path: Path.expand("~/.cache/dialyzer")
    ]
  ]
end
```

## Gotcha — do not run the toolchain as root

A mise shim resolves the toolchain from the **invoking** user's `$HOME`
(`MISE_DATA_DIR` defaults to `~/.local/share/mise`). The pair is installed as the
**agent** user, so both dispatched jobs (`User=agent`) and RDP resolve it with no
env plumbing — but `sudo mix …` resolves `/root/.local/share/mise`, finds nothing,
and either errors with `mix is not a valid shim` or (mise's
`not_found_system_fallback`, default on) **silently runs some other same-named
binary**. Run Elixir commands as `agent`; use `sudo -u agent -H` if you are already
root.

## Verify on a provisioned agent

```bash
mix --version
elixir --version
erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)])' -s init stop
mix hex.info            # Hex present for the pre-baked Elixir
ls -d ~/.cache/dialyzer
```

The **real** proof of the PATH contract is running those through a *dispatched job*
rather than an RDP shell — that is what distinguishes a working component from a
`.bashrc`-only one.

## Fleet reach

Component scripts are **not** in `base/refresh-manifest.txt`, so this lands on
**newly provisioned agents only**. An existing agent needs a redeploy.
