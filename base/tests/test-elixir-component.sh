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
grep -q 'local.hex'   "$INSTALL_SH" && ok "install.sh bootstraps mix local.hex"   || bad "install.sh never runs mix local.hex"
grep -q 'local.rebar' "$INSTALL_SH" && ok "install.sh bootstraps mix local.rebar" || bad "install.sh never runs mix local.rebar"
grep -q -- '--force'  "$INSTALL_SH" && ok "hex/rebar bootstrap is --force (non-interactive)" || bad "hex/rebar bootstrap is not --force"
grep -q 'runuser -u "\$AGENT_USER"' "$INSTALL_SH" \
  && ok "toolchain work runs as \$AGENT_USER via runuser" \
  || bad "install.sh never drops to \$AGENT_USER — a root-installed toolchain is invisible to every job"
# Strip full-line comments, then join backslash-continuations, so a runuser
# invocation that spans several lines is judged as the single command it is.
INSTALL_CODE="$(grep -vE '^[[:space:]]*#' "$INSTALL_SH" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}')"
if printf '%s\n' "$INSTALL_CODE" \
     | grep -E '(\$MISE_BIN"?[[:space:]]+(use|exec)|[[:space:]]mix[[:space:]]+local\.)' \
     | grep -qv 'runuser'; then
  bad "a mise/mix command runs bare as root — it would resolve /root's mise data dir, not the agent's"
else
  ok "every mise/mix invocation is runuser-wrapped (no root-resolved toolchain)"
fi

# ── 6. system packages (AC5) ─────────────────────────────────────────────────
for pkg in inotify-tools build-essential autoconf libssl-dev libncurses-dev; do
  grep -q -- "$pkg" "$INSTALL_SH" \
    && ok "system package '$pkg' installed" || bad "system package '$pkg' missing"
done

# ── 7. the toolchain reaches a dispatched job's PATH (AC3) ───────────────────
grep -qE 'ln -sf .*"?/usr/local/bin/' "$INSTALL_SH" \
  && ok "shims are symlinked into /usr/local/bin (systemd default PATH)" \
  || bad "nothing is linked into /usr/local/bin — dispatched jobs would not find mix"
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
grep -q 'mise activate' "$INSTALL_SH" \
  && ok "interactive/RDP shells get mise activate in .bashrc" \
  || bad "no mise activate for interactive shells"
grep -q "grep -q 'mise activate'" "$INSTALL_SH" \
  && ok ".bashrc append is grep-guarded (idempotent re-run)" \
  || bad ".bashrc append is not guarded — a re-run would duplicate the line"

# ── 8. Dialyzer PLT cache, agent-owned (AC6) ─────────────────────────────────
grep -qE 'ELIXIR_PLT_DIR=' "$INSTALL_SH" \
  && ok "a Dialyzer PLT cache dir is defined" || bad "no Dialyzer PLT cache dir"
grep -qE 'install -d -o "\$AGENT_USER".*ELIXIR_PLT_DIR|install -d -o "\$AGENT_USER"' "$INSTALL_SH" \
  && ok "PLT cache dir is created agent-owned" \
  || bad "PLT cache dir is not created agent-owned"

echo
if [ "$fail" = 0 ]; then echo "TEST PASSED"; else echo "TEST FAILED"; exit 1; fi
