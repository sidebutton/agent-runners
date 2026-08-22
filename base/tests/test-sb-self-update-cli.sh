#!/usr/bin/env bash
# base/tests/test-sb-self-update-cli.sh — guard for the sb-self-update CLI surface
# (SCRUM-2029): the argument gate and the root gate at the top of the wrapper.
#
# WHY A SEPARATE FILE FROM test-sb-self-update.sh: that one is listed in
# ci-exclude.txt (its 4d-E case false-fails on any host carrying a real global
# `sidebutton`), so anything added there does NOT run in the default suite. This
# file is fully hermetic — it never fetches, never needs root, and asserts nothing
# about host state — so it runs everywhere and the gate stays actually guarded.
#
# WHAT IT EXERCISES: the wrapper asset is executed for real, with LOG_FILE, HOME and
# AGENT_HOME pointed at a sandbox, and every case is one that exits BEFORE the
# first side effect. The bare (production) invocation is only ever run unprivileged,
# where the root gate stops it — running it as root would trigger a real fleet
# update, so that case is skipped for root instead.
#
# WHY NO `curl` STUB: the wrapper deliberately hardens PATH by PREPENDING the system
# dirs (assets/sb-self-update.sh), so a stub on PATH can never shadow /usr/bin/curl —
# by design. "Nothing was fetched" is instead established two ways that a stub could
# not fake: the exit code identifies exactly which gate fired (2 = argument gate,
# 1 = root gate, both above the fetch), and section 3 asserts structurally that both
# gates still sit above the mktemp/curl lines in the file.
# Pure bash. Run: bash base/tests/test-sb-self-update-cli.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
WRAPPER="$BASE/assets/sb-self-update.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$WRAPPER" ] || { bad "wrapper asset missing: $WRAPPER"; echo; echo "SOME FAILED"; exit 1; }

# Sandbox every path the wrapper could write to, so "wrote nothing" is checkable.
# HOME is redirected alongside AGENT_HOME on purpose. AGENT_HOME is only what the
# wrapper passes around; the two things that actually write under a home directory
# resolve HOME themselves — the pack reconcile shells out to the `sidebutton` CLI
# (~/.sidebutton) and the CLI upgrade runs npm (~/.npm). With AGENT_HOME alone a
# regressed gate would force-refresh the REAL agent's packs — the exact SCRUM-2029
# mutation — before wrote_nothing could report it. Confirmed against the pre-gate
# wrapper: with HOME sandboxed it reports "'agents' not installed ... skipped" and
# both writes land in the sandbox; without it, the live pack is refreshed.
SB_LOG="$TMP/sidebutton-update.log"
SB_HOME="$TMP/home"
mkdir -p "$SB_HOME"

# run_wrapper <args...> — execute the asset with a sandboxed env, capturing rc,
# stdout and stderr separately (the stdout-vs-stderr split IS the contract: usage
# on stdout for --help so it can be piped, on stderr for a rejection).
OUT=""; ERR=""; RC=0
run_wrapper() {
  OUT="$TMP/out"; ERR="$TMP/err"
  env LOG_FILE="$SB_LOG" AGENT_USER="$(id -un)" AGENT_HOME="$SB_HOME" HOME="$SB_HOME" \
    bash "$WRAPPER" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

# Nothing under the sandbox HOME, and no log file, may ever be created by a gated
# run — the incident behind SCRUM-2029 was a "help probe" that still mutated
# agent-owned state (~/.sidebutton packs) on its way to failing.
wrote_nothing() {
  [ ! -e "$SB_LOG" ] && [ -z "$(ls -A "$SB_HOME" 2>/dev/null)" ]
}

# The wrapper's temp dir is a hardcoded /tmp path (TMPDIR is not consulted), so it
# cannot be redirected into the sandbox — diff the siblings around the run instead.
# Matched by SET and by OWNER, never by a bare count: a real `sudo sb-self-update`
# tick creates and removes a ROOT-owned dir here at any moment, and the ops job runs
# one on a schedule on exactly the live agents where this suite gets run. A count
# would report that neighbour as this test's leak (and mask a real one behind a
# concurrent removal). Everything THIS test could create is owned by the user running
# it, since every case below exits at a gate above the mktemp.
my_tmpdirs() {
  find /tmp -maxdepth 1 -type d -name 'agent-runners-selfupdate.*' -user "$(id -u)" \
    2>/dev/null | sort
}
TMPDIRS_BEFORE="$(my_tmpdirs)"

# ── 1. --help / -h: usage on STDOUT, rc 0, no side effects, root or not ──────
for flag in --help -h; do
  run_wrapper "$flag"
  if [ "$RC" -eq 0 ]; then ok "$flag exits 0"; else bad "$flag exited $RC (want 0)"; fi
  grep -q '^usage: sudo sb-self-update' "$OUT" \
    && ok "$flag prints the usage synopsis on stdout" \
    || bad "$flag did not print usage on stdout"
  [ ! -s "$ERR" ] && ok "$flag writes nothing to stderr" || bad "$flag polluted stderr: $(cat "$ERR")"
  wrote_nothing && ok "$flag touched neither the log nor AGENT_HOME" \
    || bad "$flag created state (log or AGENT_HOME) — it must be side-effect free"
done

# The help text has to actually document the flag and the log, or it is not a
# usable answer to "what does this do before I run it?".
run_wrapper --help
grep -q -- '-h, --help' "$OUT" && ok "usage documents the --help flag" || bad "usage does not document --help"
grep -q '/var/log/sidebutton-update.log' "$OUT" && ok "usage names the log file" || bad "usage omits the log file"
grep -q 'NO arguments' "$OUT" && ok "usage states the wrapper takes no arguments" || bad "usage does not state the no-argument contract"

# ── 2. every other argument shape: rc 2, usage on STDERR, nothing done ───────
# Fail-closed. Before SCRUM-2029 each of these fell through into a real update run.
while IFS='|' read -r label args; do
  [ -n "$label" ] || continue
  # shellcheck disable=SC2086  # deliberate word-split: the case supplies argv
  run_wrapper $args
  [ "$RC" -eq 2 ] && ok "rejects $label with rc 2" || bad "$label exited $RC (want 2)"
  grep -q 'unrecognized argument' "$ERR" \
    && ok "rejects $label with an 'unrecognized argument' message" \
    || bad "$label produced no unrecognized-argument message"
  grep -q '^usage: sudo sb-self-update' "$ERR" \
    && ok "rejects $label with usage on stderr" || bad "$label did not print usage to stderr"
  [ ! -s "$OUT" ] && ok "$label keeps stdout clean" || bad "$label wrote usage to stdout (must be stderr)"
  wrote_nothing && ok "$label fetched/refreshed nothing" || bad "$label created state"
done <<'CASES'
--frobnicate|--frobnicate
a stale --force habit|--force
positional junk|foo bar
--help with extra args|--help extra
-h with extra args|-h extra
CASES

# ── 3. gate ordering: both gates sit ABOVE every side effect ─────────────────
# Structural, so a later edit that moves the fetch up (or the gates down) fails
# here even though every behavioural case above would still pass.
line_of() { grep -n -m1 -- "$1" "$WRAPPER" | cut -d: -f1; }
L_ARGGATE="$(line_of 'unrecognized argument')"
L_ROOTGATE="$(line_of 'must run as root')"
L_MKTEMP="$(line_of 'mktemp -d /tmp/agent-runners-selfupdate')"
L_CURL="$(line_of 'curl -fsSL')"
if [ -n "$L_ARGGATE" ] && [ -n "$L_ROOTGATE" ] && [ -n "$L_MKTEMP" ] && [ -n "$L_CURL" ]; then
  [ "$L_ARGGATE" -lt "$L_MKTEMP" ] && [ "$L_ROOTGATE" -lt "$L_MKTEMP" ] && [ "$L_MKTEMP" -lt "$L_CURL" ] \
    && ok "both gates precede the mktemp ($L_MKTEMP) and the fetch ($L_CURL)" \
    || bad "a gate is below a side effect (arg=$L_ARGGATE root=$L_ROOTGATE mktemp=$L_MKTEMP curl=$L_CURL)"
else
  bad "could not locate the gates / side effects in the wrapper (arg=$L_ARGGATE root=$L_ROOTGATE mktemp=$L_MKTEMP curl=$L_CURL)"
fi

# ── 4. bare invocation (the production form) ─────────────────────────────────
# Unprivileged: must refuse with rc 1 having done NOTHING. rc 1 + the root message
# (rather than rc 2) is also what proves the no-argument path cleared the argument
# gate — i.e. `sudo sb-self-update` still reaches the update body unchanged.
if [ "$(id -u)" -ne 0 ]; then
  run_wrapper
  [ "$RC" -eq 1 ] && ok "unprivileged bare run refuses with rc 1" || bad "unprivileged bare run exited $RC (want 1)"
  grep -q 'must run as root' "$ERR" \
    && ok "unprivileged bare run explains how to re-run it (sudo)" \
    || bad "unprivileged bare run gave no root-required message"
  grep -q 'unrecognized argument' "$ERR" \
    && bad "no-argument run hit the ARGUMENT gate — the production form is broken" \
    || ok "no-argument run clears the argument gate (reaches the root gate, not rc 2)"
  wrote_nothing && ok "unprivileged bare run mutated nothing (no partial update)" \
    || bad "unprivileged bare run created state — the SCRUM-2029 regression"
else
  printf 'skip - bare-invocation cases (running as root would start a REAL update)\n'
fi

# ── 5. no temp dir escaped any gated run ────────────────────────────────────
LEAKED="$(comm -13 <(printf '%s\n' "$TMPDIRS_BEFORE") <(my_tmpdirs))"
[ -z "$LEAKED" ] \
  && ok "no /tmp/agent-runners-selfupdate.* left behind by any gated run" \
  || bad "a gated run leaked a temp dir: $(printf '%s' "$LEAKED" | tr '\n' ' ')"

# ── 6. syntax + install shape of the asset ──────────────────────────────────
# Duplicated from the CI-excluded sibling on purpose: this is the only file that
# actually runs `bash -n` on the wrapper in the default suite.
bash -n "$WRAPPER" 2>/dev/null && ok "bash -n: assets/sb-self-update.sh" || bad "bash -n failed on the wrapper"
head -1 "$WRAPPER" | grep -q '^#!' && ok "wrapper asset has a shebang" || bad "wrapper asset missing shebang"
[ -x "$WRAPPER" ] && ok "wrapper asset is executable" || bad "wrapper asset not executable"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
