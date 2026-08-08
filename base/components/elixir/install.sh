# components/elixir/install.sh — Erlang/OTP + Elixir (mise-managed toolchain).
#
# Sourced by base/run.sh when `elixir` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs mise system-wide, PRE-BAKES one pinned Erlang/OTP +
# Elixir pair as the agent user (so no dispatched job ever pays a cold toolchain
# cost), bootstraps Hex + rebar3, and symlinks the resulting shims onto
# /usr/local/bin. Idempotent.
#
# WHY THE SHIM SYMLINKS — the load-bearing part. sidebutton.service is `User=agent`
# with an EnvironmentFile and NO `Environment=PATH=` (base/16-services-prep.sh), so a
# DISPATCHED job inherits systemd's default PATH and reads neither ~/.bashrc nor
# /etc/environment. `mise activate` in .bashrc alone would give a working RDP shell
# and `mix: command not found` on every dispatched job — exactly the silent-failure
# class base/tests/test-component-resolution.sh exists to catch. /usr/local/bin IS on
# systemd's default PATH, which is why dotnet9 symlinks /usr/local/bin/dotnet and
# android-sdk symlinks adb/sdkmanager. Two constraints on these links:
#   * the basename MUST equal the tool name — mise dispatches a shim on argv[0];
#     a renamed link dies with "<name> is not a valid shim".
#   * shims re-resolve the version from the CWD at exec time, so the symlinks
#     preserve the .tool-versions override promise rather than freezing the pin.
#
# WHY AS THE AGENT USER — a shim resolves the toolchain from the INVOKING user's
# $HOME (MISE_DATA_DIR defaults to ~/.local/share/mise). Installed as root the pair
# would land in /root and every agent-user job would miss it; `sudo mix` on a
# provisioned agent misses it for the same reason (see docs/ELIXIR.md).

step "Component: Elixir"

# Pinned toolchain — ONE pair pre-baked; bump deliberately. Erlang installs from a
# builds.hex.pm PRECOMPILED tarball where one exists for this platform (seconds);
# mise silently falls back to a kerl SOURCE build (10–20 min) when it does not,
# which is why the build deps below are installed unconditionally.
# The -otp-NN suffix on ELIXIR_VERSION MUST match ELIXIR_OTP_VERSION's major:
# Elixir's precompiled builds are OTP-major-keyed, and omitting the suffix silently
# gets the build for the OLDEST supported OTP.
MISE_VERSION_PIN=v2026.8.3
ELIXIR_OTP_VERSION=28.5.0.5
ELIXIR_VERSION=1.20.3-otp-28

MISE_BIN=/usr/local/bin/mise
ELIXIR_SHIM_DIR="$AGENT_HOME/.local/share/mise/shims"
ELIXIR_PLT_DIR="$AGENT_HOME/.cache/dialyzer"
# Shims to expose on /usr/local/bin. Deliberately NOT here: `rebar3` (mix installs a
# mix-private rebar3 inside MIX_HOME and mise creates no rebar3 shim — linking it
# would strand a dangling symlink) and `mix.ps1` (PowerShell wrapper).
ELIXIR_SHIMS=(elixir elixirc mix iex erl erlc escript epmd dialyzer typer)

# ── 1. System packages ───────────────────────────────────────────────────────
# inotify-tools: Phoenix live-reload + `mix test.watch` file watchers.
# The rest are the Erlang source-build deps — installed even when a precompiled
# OTP is expected, so the kerl fallback below is survivable rather than fatal.
apt-get install "${APT_OPTS[@]}" inotify-tools build-essential autoconf libssl-dev libncurses-dev \
  || log "WARN: Elixir system package install failed"

# ── 2. mise, system-wide ─────────────────────────────────────────────────────
if [ -x "$MISE_BIN" ]; then
  log "mise already installed: $("$MISE_BIN" --version 2>/dev/null)"
else
  if curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 --retry-connrefused \
       https://mise.run -o /tmp/mise-install.sh; then
    # MISE_INSTALL_PATH is a full FILE path (the installer rejects a directory).
    MISE_INSTALL_PATH="$MISE_BIN" MISE_VERSION="$MISE_VERSION_PIN" MISE_INSTALL_HELP=0 \
      sh /tmp/mise-install.sh >>"$LOG_FILE" 2>&1 || log "WARN: mise install failed"
    rm -f /tmp/mise-install.sh
  else
    log "WARN: could not download the mise installer — Elixir toolchain not installed"
  fi
fi

if [ ! -x "$MISE_BIN" ]; then
  log "WARN: no mise binary at ${MISE_BIN} — skipping the Elixir toolchain"
else
  # ── 3. Predict the Erlang install path ─────────────────────────────────────
  # Replicates mise's own decision (src/plugins/core/erlang.rs): it builds
  # https://builds.hex.pm/builds/otp/{amd64|arm64}/{ID}-{VERSION_ID}/OTP-<ver>.tar.gz
  # from /etc/os-release and falls back to a kerl source build on any miss. Probing
  # it here turns a mystery 20-minute provision into one greppable log line.
  _os_ver="$( . /etc/os-release 2>/dev/null && echo "${ID:-unknown}-${VERSION_ID:-unknown}" || echo unknown-unknown )"
  _arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  # --retry matches the repo's fetch idiom (dotnet9/install.sh:14): a fresh cloud
  # VM whose egress is still settling would otherwise fail the HEAD once and log
  # the alarming "expect 10–20 min" line for an install that takes seconds.
  if curl -fsI --connect-timeout 10 --max-time 30 --retry 2 --retry-connrefused \
       "https://builds.hex.pm/builds/otp/${_arch}/${_os_ver}/OTP-${ELIXIR_OTP_VERSION}.tar.gz" \
       >/dev/null 2>&1; then
    log "elixir: precompiled OTP-${ELIXIR_OTP_VERSION} available for ${_arch}/${_os_ver} — install is a download"
  else
    log "elixir: NO precompiled OTP-${ELIXIR_OTP_VERSION} for ${_arch}/${_os_ver} — mise will kerl SOURCE-build it (expect 10–20 min)"
  fi

  # ── 4. Give the agent its own dotdirs BEFORE dropping to it ────────────────
  # base/09-agent-user.sh creates $AGENT_HOME/.config and $AGENT_HOME/.local/bin
  # with `mkdir -p` AS ROOT, and the first `chown -R "$AGENT_HOME"` does not run
  # until 13-knowledge-packs / 15-claude-mcp — i.e. AFTER this toolchain loop
  # (run.sh sources components at :50, those steps at :70/:72). So at this point
  # both dirs are root:root 0755 and the agent cannot create anything under them.
  # Without this block the `mise use -g` below dies with
  #   failed create_dir_all: ~/.local/share/mise/installs/…: Permission denied (13)
  # which `|| log WARN` swallows — a GREEN provision with no toolchain, no shims
  # and `mix: command not found` on every dispatched job. `install -d` re-applies
  # ownership to an existing dir, so this is also a no-op on a re-run.
  for _d in "$AGENT_HOME/.config" "$AGENT_HOME/.local" "$AGENT_HOME/.local/share" "$AGENT_HOME/.cache"; do
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$_d" \
      || log "WARN: could not give ${AGENT_USER} ownership of ${_d}"
  done

  # ── 5. Pre-bake the pinned pair AS THE AGENT USER ──────────────────────────
  # `mise use -g` installs the tools AND records them in the agent's global
  # ~/.config/mise/config.toml. MISE_YES=1 keeps it non-interactive (the only
  # prompt on this path is the config-trust one). `runuser -u` (no -m) resets HOME
  # to the target user; HOME is passed explicitly anyway because every path mise
  # resolves hangs off it.
  _t0="$(date +%s)"
  runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" MISE_YES=1 \
    "$MISE_BIN" use -g "erlang@${ELIXIR_OTP_VERSION}" "elixir@${ELIXIR_VERSION}" >>"$LOG_FILE" 2>&1 \
    || log "WARN: mise install of erlang@${ELIXIR_OTP_VERSION} + elixir@${ELIXIR_VERSION} failed"
  log "elixir: toolchain install took $(( $(date +%s) - _t0 ))s"

  # ── 6. Bootstrap Hex + rebar3 (as the agent) ───────────────────────────────
  # NOTE: mise's elixir plugin points MIX_HOME at the ELIXIR INSTALL DIR
  # (…/installs/elixir/<version>/.mix), NOT ~/.mix — so this bootstrap is
  # per-Elixir-version. A repo whose .tool-versions selects a different Elixir gets
  # its own empty MIX_HOME and re-fetches Hex on first use (needs network).
  # Called out in docs/ELIXIR.md.
  # GATED on the pre-bake having actually produced a mix shim: with MISE_YES=1,
  # `mise exec` AUTO-INSTALLS a missing tool, so running this after a failed
  # step 5 would re-attempt the (possibly 10–20 min kerl) Erlang build once per
  # loop iteration, unbounded, and still end with no Hex.
  if [ ! -x "$ELIXIR_SHIM_DIR/mix" ]; then
    log "WARN: no mix shim after the pre-bake — skipping the Hex/rebar bootstrap"
  else
    for _mixtask in local.hex local.rebar; do
      runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" MISE_YES=1 \
        "$MISE_BIN" exec -- mix "$_mixtask" --force >>"$LOG_FILE" 2>&1 \
        || log "WARN: mix ${_mixtask} --force failed"
    done
  fi

  # ── 7. Put the toolchain on the DISPATCHED-JOB PATH (see header) ───────────
  for _b in "${ELIXIR_SHIMS[@]}"; do
    if [ -e "$ELIXIR_SHIM_DIR/$_b" ]; then
      ln -sf "$ELIXIR_SHIM_DIR/$_b" "/usr/local/bin/$_b" || log "WARN: could not link ${_b} into /usr/local/bin"
    else
      log "WARN: no mise shim for '${_b}' — not linked into /usr/local/bin"
    fi
  done

  # Interactive / RDP shells get a real `mise activate` (PATH-based, no shim
  # indirection). Guarded append — the base/12-workspace.sh .bashrc idiom.
  if ! grep -q 'mise activate' "$AGENT_HOME/.bashrc" 2>/dev/null; then
    printf 'eval "$(%s activate bash)"\n' "$MISE_BIN" >> "$AGENT_HOME/.bashrc" \
      || log "WARN: could not append mise activate to ${AGENT_HOME}/.bashrc"
    chown "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME/.bashrc" 2>/dev/null || true
  fi

  # ── 8. Dialyzer PLT cache ──────────────────────────────────────────────────
  # Agent-owned and OUTSIDE any repo, so the slow core PLT survives a fresh clone
  # or a branch switch. Repos opt in via `dialyzer: [plt_local_path: …]` in
  # mix.exs — see docs/ELIXIR.md.
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$ELIXIR_PLT_DIR" \
    || log "WARN: could not create the Dialyzer PLT cache dir ${ELIXIR_PLT_DIR}"

  # ── 9. Report what actually resolved ───────────────────────────────────────
  # AS THE AGENT, for the same reason everything else here is: these are the mise
  # SHIMS, and a shim resolves the toolchain from the INVOKING user's $HOME. Run
  # bare as root they look in /root/.local/share/mise, find nothing, and exit 1
  # with "elixir is not a valid shim" — so a perfectly healthy install would log
  # "elixir: not-installed" / "erlang: OTP unknown" every single time, breaking
  # the exact triage path docs/ELIXIR.md tells operators to grep for. (With mise's
  # not_found_system_fallback the root probe can also silently report an unrelated
  # same-named binary.) One `elixir --version` carries BOTH the OTP and the Elixir
  # banner, so this is also one BEAM start instead of two.
  _elixir_v="$(runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" \
    /usr/local/bin/elixir --version 2>/dev/null || echo '')"
  if [ -n "$_elixir_v" ]; then
    log "elixir: $(printf '%s\n' "$_elixir_v" | grep -i '^Elixir' || echo unknown)"
    log "erlang: $(printf '%s\n' "$_elixir_v" | grep -i '^Erlang' || echo unknown) — PLT cache ${ELIXIR_PLT_DIR}"
  else
    log "elixir: not-installed (the toolchain did not resolve as ${AGENT_USER} — see the WARNs above)"
  fi
fi
