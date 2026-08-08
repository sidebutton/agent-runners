#!/usr/bin/env bash
# base/tests/test-elixir-component.sh — guard for the elixir component (SCRUM-1890).
#
# The `elixir` toolchain component follows the dotnet9 / android-sdk pattern: a
# components.json entry, base/components/elixir/install.sh, and — the real wiring
# point — inclusion in the base/run.sh toolchain loop (without it the dir + JSON
# exist but the component never installs).
#
# Beyond the wiring, this pins the install contract that makes Elixir work on a
# DISPATCHED job rather than only in an RDP shell:
#
#   * the toolchain reaches /usr/local/bin. sidebutton.service is User=agent with
#     no `Environment=PATH=`, so a job inherits systemd's default PATH and reads
#     neither ~/.bashrc nor /etc/environment — a .bashrc-only `mise activate`
#     would give `mix: command not found` on every dispatched job.
#   * mise runs AS THE AGENT USER. A shim resolves the toolchain from the invoking
#     user's $HOME; installed as root the pair lands in /root and no job sees it.
#   * versions are PINNED (a cold Erlang build is 10–20 min — never at job time),
#     and the Elixir build's -otp-NN suffix matches the pinned OTP major. Elixir's
#     precompiled builds are OTP-major-keyed; a mismatched/absent suffix silently
#     yields the build for the OLDEST supported OTP.
#   * no dangling symlinks: mise creates NO rebar3 shim (mix installs a private
#     rebar3 inside MIX_HOME), and mix.ps1 is a PowerShell wrapper.
#   * the description carries the machine guidance the wizard renders verbatim
#     (docker pairing for a real Postgres; disk sizing) — there is no per-component
#     disk dimension in the portal, so the description is the only channel.
#
# Deliberately NOT asserted: any profiles.json preset. This component is
# catalog-only by design (a preset would shift the default-install parity snapshot
# and widen the operator re-vendor gate) — see SCRUM-1896.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-elixir-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_JSON="$ROOT/components.json"
RUN_SH="$ROOT/base/run.sh"
COMP_DIR="$ROOT/base/components/elixir"
INSTALL_SH="$COMP_DIR/install.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# The install script is 56% comment, and every prose paragraph names the very
# strings these assertions grep for ("mise activate", "--force", "inotify-tools",
# …). Greping the RAW file therefore lets a comment satisfy a guard while the
# code it describes is gone. Strip full-line comments once, then join
# backslash-continuations so a command spanning several lines is judged as the
# single command it is, and assert against THIS — never against $INSTALL_SH.
INSTALL_CODE="$(grep -vE '^[[:space:]]*#' "$INSTALL_SH" 2>/dev/null \
  | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}')"
# grep the code, not the prose
cgrep() { printf '%s\n' "$INSTALL_CODE" | grep "$@" >/dev/null 2>&1; }

# ── 1. catalog entry (AC1) ───────────────────────────────────────────────────
jq -e . "$COMPONENTS_JSON" >/dev/null 2>&1 \
  && ok "components.json is valid JSON" || bad "components.json is not valid JSON"

entry="$(jq -c '.components[] | select(.slug=="elixir")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$entry" ] \
  && ok "components.json has an elixir entry" || bad "components.json missing the elixir entry"
[ -n "$entry" ] \
  && printf '%s' "$entry" | jq -e 'has("slug") and has("kind") and has("title") and has("requires") and (.chip|has("label") and has("live"))' >/dev/null 2>&1 \
  && ok "elixir entry has the required keys (slug/kind/title/requires/chip)" \
  || bad "elixir entry missing required keys"
[ "$(printf '%s' "$entry" | jq -r '.kind' 2>/dev/null)" = "toolchain" ] \
  && ok "elixir kind is toolchain" || bad "elixir kind is not toolchain"
[ "$(printf '%s' "$entry" | jq -r '.requires | length' 2>/dev/null)" = "0" ] \
  && ok "elixir requires[] is empty (docker pairing is advisory, not a hard dep)" \
  || bad "elixir requires[] is not empty"

# AC7 — the description is the ONLY machine-guidance channel the wizard renders.
desc="$(printf '%s' "$entry" | jq -r '.description // ""' 2>/dev/null)"
printf '%s' "$desc" | grep -qi 'docker' \
  && ok "description documents the docker pairing (real Postgres server)" \
  || bad "description does not mention the docker pairing — Phoenix test suites need a real Postgres"
printf '%s' "$desc" | grep -qi 'postgres-client' \
  && ok "description says postgres-client alone is not enough" \
  || bad "description does not warn that postgres-client alone is insufficient"
printf '%s' "$desc" | grep -qiE 'disk|GB' \
  && ok "description documents disk sizing (no per-component disk dimension exists)" \
  || bad "description carries no disk-sizing guidance"
printf '%s' "$desc" | grep -qi 'tool-versions' \
  && ok "description states the .tool-versions override still applies" \
  || bad "description does not mention the .tool-versions override"

# ── 2. component dir resolves + parses (AC2) ─────────────────────────────────
[ -d "$COMP_DIR" ]   && ok "base/components/elixir/ exists" || bad "base/components/elixir/ missing"
[ -f "$INSTALL_SH" ] && ok "install.sh present"             || bad "install.sh missing"
bash -n "$INSTALL_SH" 2>/dev/null \
  && ok "install.sh parses (bash -n)" || bad "install.sh does not parse"

# ── 3. run.sh toolchain loop includes elixir (AC8 — the real wiring point) ───
grep -qE 'for _tc in[^;]*\belixir\b' "$RUN_SH" \
  && ok "base/run.sh toolchain loop includes elixir" \
  || bad "base/run.sh toolchain loop does NOT include elixir (component would never install)"

# ── 4. versions pinned, and the -otp-NN suffix matches the OTP major ─────────
grep -qE '^ELIXIR_OTP_VERSION=[0-9]+(\.[0-9]+)*$' "$INSTALL_SH" \
  && ok "Erlang/OTP version is pinned (no floating latest)" \
  || bad "ELIXIR_OTP_VERSION is not a pinned literal"
grep -qE '^ELIXIR_VERSION=[0-9]+(\.[0-9]+)*-otp-[0-9]+$' "$INSTALL_SH" \
  && ok "Elixir version is pinned and carries an -otp-NN suffix" \
  || bad "ELIXIR_VERSION is not pinned with an -otp-NN suffix"
grep -qE '^MISE_VERSION_PIN=v?[0-9]' "$INSTALL_SH" \
  && ok "mise version is pinned" || bad "mise version is not pinned"

otp_major="$(grep -oE '^ELIXIR_OTP_VERSION=[0-9]+' "$INSTALL_SH" 2>/dev/null | cut -d= -f2)"
elx_suffix="$(grep -oE '^ELIXIR_VERSION=[0-9.]+-otp-[0-9]+' "$INSTALL_SH" 2>/dev/null | sed 's/.*-otp-//')"
if [ -n "$otp_major" ] && [ "$otp_major" = "$elx_suffix" ]; then
  ok "Elixir -otp-${elx_suffix} matches the pinned OTP major (${otp_major})"
else
  bad "Elixir -otp-${elx_suffix:-?} does NOT match the pinned OTP major (${otp_major:-?}) — silently yields the build for the oldest supported OTP"
fi

# ── 5. Hex + rebar bootstrapped, as the agent (AC4) ──────────────────────────
cgrep -F 'local.hex'   && ok "install.sh bootstraps mix local.hex"   || bad "install.sh never runs mix local.hex"
cgrep -F 'local.rebar' && ok "install.sh bootstraps mix local.rebar" || bad "install.sh never runs mix local.rebar"
# Anchored to the invocation, not the file: the WARN string on the next line also
# contains "--force", so a bare whole-file grep passes even if the flag is dropped
# from the command — and without it `mix local.hex` PROMPTS on a non-TTY provision.
cgrep -E 'mix "\$_mixtask" --force' \
  && ok "hex/rebar bootstrap passes --force on the invocation (non-interactive)" \
  || bad "the mix local.hex/local.rebar invocation is not --force — it would prompt on a non-TTY provision"

# The agent must own ~/.config and ~/.local BEFORE any runuser drop: 09-agent-user.sh
# mkdir's them as root and the first `chown -R $AGENT_HOME` (13/15) runs AFTER the
# run.sh toolchain loop, so without this prep `mise use -g` dies EACCES and the whole
# toolchain is silently skipped on a green provision.
for _need in '\.config' '\.local' '\.cache'; do
  cgrep -E "for _d in .*\"\\\$AGENT_HOME/${_need}\"" \
    && ok "\$AGENT_HOME/$(printf '%s' "$_need" | tr -d '\\') is in the ownership-prep list" \
    || bad "\$AGENT_HOME/$(printf '%s' "$_need" | tr -d '\\') is never made agent-owned — mise would fail EACCES (root-owned until 13/15)"
done
cgrep -E 'install -d -o "\$AGENT_USER" -g "\$AGENT_USER".*"\$_d"' \
  && ok "the ownership-prep loop actually chowns each dir to \$AGENT_USER" \
  || bad "the ownership-prep list is not applied with install -d -o \$AGENT_USER"
# …and it must come BEFORE the first drop to the agent, or it fixes nothing.
_prep_ln="$(printf '%s\n' "$INSTALL_CODE" | grep -n 'for _d in' | head -1 | cut -d: -f1)"
_drop_ln="$(printf '%s\n' "$INSTALL_CODE" | grep -n 'runuser -u' | head -1 | cut -d: -f1)"
if [ -n "$_prep_ln" ] && [ -n "$_drop_ln" ] && [ "$_prep_ln" -lt "$_drop_ln" ]; then
  ok "the ownership prep runs before the first runuser drop"
else
  bad "the ownership prep does not precede the first runuser drop — mise would still hit EACCES"
fi

cgrep -F 'runuser -u "$AGENT_USER"' \
  && ok "toolchain work runs as \$AGENT_USER via runuser" \
  || bad "install.sh never drops to \$AGENT_USER — a root-installed toolchain is invisible to every job"

# EVERY toolchain invocation must be runuser-wrapped — including the mise SHIMS
# (/usr/local/bin/elixir, …), which resolve the toolchain from the INVOKING user's
# $HOME. Run bare as root a shim finds /root's empty mise data dir and exits
# "not a valid shim" (or, with not_found_system_fallback, silently runs an
# unrelated same-named binary). The matcher must also be non-vacuous: `grep -qv`
# on EMPTY input returns 1, which would print ok while asserting nothing.
_tc_calls="$(printf '%s\n' "$INSTALL_CODE" \
  | grep -E '(\$MISE_BIN"?[[:space:]]+[a-z]|/usr/local/bin/(elixir|elixirc|mix|iex|erl|erlc|escript|epmd|dialyzer|typer)\b)')"
if [ -z "$_tc_calls" ]; then
  bad "found no mise/shim invocations at all — the runuser guard would pass vacuously"
elif printf '%s\n' "$_tc_calls" | grep -qv 'runuser'; then
  bad "a mise/shim command runs bare as root — it would resolve /root's mise data dir, not the agent's:
$(printf '%s\n' "$_tc_calls" | grep -v 'runuser' | sed 's/^/       /')"
else
  ok "every mise + shim invocation is runuser-wrapped (no root-resolved toolchain)"
fi

# install.sh is SOURCED by run.sh under `set -euo pipefail` — an `exit` here kills
# the whole provision before services/heartbeat. Components WARN and continue.
cgrep -E '^[[:space:]]*(exit|die)[[:space:]]' \
  && bad "install.sh exits/dies — sourced into run.sh this aborts the entire provision; WARN and continue instead" \
  || ok "no exit/die: the component WARNs and continues (sourced-safe)"

# ── 6. system packages (AC5) ─────────────────────────────────────────────────
# Against the CODE: install.sh's comments name inotify-tools by hand, so a raw
# grep stays green even with the package dropped from the apt-get line.
for pkg in inotify-tools build-essential autoconf libssl-dev libncurses-dev; do
  cgrep -E "apt-get install.*[[:space:]]${pkg}([[:space:]]|\\\\|$)" \
    && ok "system package '$pkg' is on the apt-get line" \
    || bad "system package '$pkg' is not passed to apt-get install"
done

# ── 7. the toolchain reaches a dispatched job's PATH (AC3) ───────────────────
# The link BASENAME must be preserved: mise dispatches a shim on argv[0], so
# /usr/local/bin/sb-mix would die "sb-mix is not a valid shim" while this guard,
# if it only looked for the string /usr/local/bin/, stayed green.
cgrep -E 'ln -sf "\$ELIXIR_SHIM_DIR/\$_b" "/usr/local/bin/\$_b"' \
  && ok "shims are symlinked into /usr/local/bin under their own basename (systemd default PATH)" \
  || bad "the /usr/local/bin link does not preserve the tool basename — mise dispatches shims on argv[0]"
for b in elixir mix iex erl; do
  grep -qE "ELIXIR_SHIMS=\(.*\b${b}\b" "$INSTALL_SH" \
    && ok "'${b}' is in the linked shim set" || bad "'${b}' is not linked onto /usr/local/bin"
done
grep -qE 'ELIXIR_SHIMS=\(.*\brebar3\b' "$INSTALL_SH" \
  && bad "rebar3 is in the shim set — mise creates no rebar3 shim, so the link would dangle" \
  || ok "rebar3 is not linked (mix keeps a private rebar3 in MIX_HOME; no mise shim exists)"
grep -qE 'ELIXIR_SHIMS=\(.*mix\.ps1' "$INSTALL_SH" \
  && bad "mix.ps1 (PowerShell wrapper) is in the shim set" \
  || ok "mix.ps1 is not linked"
# The APPEND must exist, not merely the words "mise activate" (they appear in two
# comments); and it must stay grep-guarded so a re-provision does not duplicate it.
cgrep -E 'activate bash.*>> "\$AGENT_HOME/\.bashrc"' \
  && ok "interactive/RDP shells get mise activate appended to .bashrc" \
  || bad "install.sh never appends 'mise activate' to .bashrc — RDP shells get no PATH-based toolchain"
cgrep -F "grep -q 'mise activate'" \
  && ok ".bashrc append is grep-guarded (idempotent re-run)" \
  || bad ".bashrc append is not guarded — a re-run would duplicate the line"

# ── 8. Dialyzer PLT cache, agent-owned (AC6) ─────────────────────────────────
cgrep -E '^ELIXIR_PLT_DIR=' \
  && ok "a Dialyzer PLT cache dir is defined" || bad "no Dialyzer PLT cache dir"
# Anchored to ELIXIR_PLT_DIR: the component now has several `install -d -o
# "$AGENT_USER"` calls (the .config/.local ownership prep), so an unanchored
# pattern would pass even with the PLT dir never created.
cgrep -E 'install -d -o "\$AGENT_USER".*"\$ELIXIR_PLT_DIR"' \
  && ok "the PLT cache dir itself is created agent-owned" \
  || bad "\$ELIXIR_PLT_DIR is not the thing created by install -d -o \$AGENT_USER"

echo
if [ "$fail" = 0 ]; then echo "TEST PASSED"; else echo "TEST FAILED"; exit 1; fi
