#!/usr/bin/env bash
# base/tests/test-sb-self-update-claude.sh — guard for the Claude Code step of
# sb-self-update (base/lib-refresh.sh sb_refresh_claude_code).
#
# Claude Code is installed once at provisioning with its autoupdater off, so this
# step is what keeps a live agent on the fleet's target version. It runs as root,
# swaps the global npm install in place and replaces the runtime every job depends
# on — each guard below maps to a way it could leave an agent without a working
# `claude`, or skip the upgrade the fleet needs.
#
# HERMETIC by construction, so it is NOT in ci-exclude.txt: npm, df, uname and
# systemctl are stubs on PATH, the npm prefix is a sandbox dir, and every health
# check the step makes is prefix-local ($prefix/bin/claude) — a real `claude` or
# npm on the host is never consulted. That prefix-local check is itself one of the
# guarded properties: a PATH lookup is what keeps test-sb-self-update.sh excluded.
# Pure bash + jq. Run: bash base/tests/test-sb-self-update-claude.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate every root-owned / agent-owned path before sourcing the lib.
export SB_UPDATED_MARKER="$TMP/updated"
export SB_SELF_UPDATE_BIN="$TMP/sb-self-update.bin"
export AGENT_USER="$(id -un)"
export AGENT_HOME="$TMP/home"
export SKIP_KNOWLEDGE_PACKS=1
mkdir -p "$AGENT_HOME"

# shellcheck source=../lib-refresh.sh
. "$BASE/lib-refresh.sh"

# ── sandbox: npm prefix, fake claude, stubs, fake base tree ──────────────────
CC="$TMP/cc"
PREFIX="$CC/prefix"
PKG="$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
FB="$CC/base"
mkdir -p "$CC/stub" "$PREFIX/bin" "$PKG" "$FB/components/claude-code"

# The fake binary reports what the fake npm last "installed", unless that install
# was marked broken — then it does not run at all.
cat > "$PREFIX/bin/claude" <<'SH'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
[ -e "$d/broken" ] && exit 127
printf '%s (Claude Code)\n' "$(cat "$d/claude.ver")"
SH

# npm: records every call; serves `prefix -g`, `view`, `cache add`, `install -g`
# against the sandbox prefix. SB_T_BROKEN_VERSIONS lists versions whose install
# leaves a binary that does not run.
cat > "$CC/stub/npm" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${SB_T_CALLS:-/dev/null}"
case "${1:-}" in
  prefix) printf '%s\n' "$SB_T_PREFIX" ;;
  view)   [ "${SB_T_REGISTRY_DOWN:-0}" = 1 ] && exit 1; printf '%s\n' "${SB_T_LATEST:-2.1.280}" ;;
  cache)  exit "${SB_T_CACHE_RC:-0}" ;;
  install)
    v=""
    for a in "$@"; do case "$a" in @anthropic-ai/claude-code@*) v="${a##*@}" ;; esac; done
    [ -n "$v" ] || exit 1
    printf '{"name":"@anthropic-ai/claude-code","version":"%s"}\n' "$v" \
      > "$SB_T_PREFIX/lib/node_modules/@anthropic-ai/claude-code/package.json"
    printf '%s\n' "$v" > "$SB_T_PREFIX/claude.ver"
    if printf '%s\n' ${SB_T_BROKEN_VERSIONS:-} | grep -qx "$v"; then
      : > "$SB_T_PREFIX/broken"
    else
      rm -f "$SB_T_PREFIX/broken"
    fi ;;
esac
exit 0
SH
cat > "$CC/stub/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1M-blocks Used Avail Cap Mounted"
echo "/dev/root 38000 1000 ${SB_T_FREE_MB:-30000} 5% /"
SH
cat > "$CC/stub/uname" <<'SH'
#!/usr/bin/env bash
echo x86_64
SH
cat > "$CC/stub/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$PREFIX/bin/claude" "$CC"/stub/*

# Fake base tree: the lib only needs lib.sh (sourced by _sb_run_base_step) and 15b.
# The stub 15b records its run and stamps the release notes the way the real step
# does (lastReleaseNotesSeen = the installed CLI's version).
cat > "$FB/lib.sh" <<'SH'
log() { :; }
step() { :; }
SH
cat > "$FB/15b-claude-onboarding.sh" <<'SH'
echo ran >> "$SB_T_15B_CALLS"
v="$("$SB_T_PREFIX/bin/claude" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf '{"lastReleaseNotesSeen":"%s"}\n' "$v" > "$AGENT_HOME/.claude.json"
SH

# set_installed <version> [release-notes-seen] — reset the sandbox to a healthy install.
set_installed() {
  printf '{"name":"@anthropic-ai/claude-code","version":"%s"}\n' "$1" > "$PKG/package.json"
  printf '%s\n' "$1" > "$PREFIX/claude.ver"
  rm -f "$PREFIX/broken"
  printf '{"lastReleaseNotesSeen":"%s"}\n' "${2:-$1}" > "$AGENT_HOME/.claude.json"
}
set_want() { printf '# target\n%s\n' "$1" > "$FB/components/claude-code/version"; }

# run_step <id> [VAR=value ...] — run the step with the stubs first on PATH; leaves
# $TMP/<id>.out (stdout), .rc, .calls (npm calls) and .15b (15b runs).
run_step() {
  local id="$1"; shift
  (
    export PATH="$CC/stub:$PATH" SB_T_PREFIX="$PREFIX" \
           SB_T_CALLS="$TMP/$id.calls" SB_T_15B_CALLS="$TMP/$id.15b"
    [ "$#" -gt 0 ] && export "$@"
    sb_refresh_claude_code "$FB" >"$TMP/$id.out" 2>/dev/null
    echo "$?" > "$TMP/$id.rc"
  )
}
out()     { cat "$TMP/$1.out" 2>/dev/null; }
rc()      { cat "$TMP/$1.rc" 2>/dev/null; }
called()  { grep -q -- "$2" "$TMP/$1.calls" 2>/dev/null; }
ran15b()  { [ -s "$TMP/$1.15b" ]; }
seen()    { jq -r '.lastReleaseNotesSeen // empty' "$AGENT_HOME/.claude.json" 2>/dev/null; }
runs_as() { "$PREFIX/bin/claude" --version 2>/dev/null | grep -q "^$1 "; }

# ── 1. target file parsing ────────────────────────────────────────────────────
set_want latest
[ "$(_sb_claude_want "$FB")" = "latest" ] && ok "version file: 'latest' read past the comment line" || bad "version file: 'latest' not parsed"
printf '\n  # pinned while a release is bad\n  2.1.278   # trailing note\n' > "$FB/components/claude-code/version"
[ "$(_sb_claude_want "$FB")" = "2.1.278" ] && ok "version file: first non-comment token wins" || bad "version file: pinned version not parsed"
rm -f "$FB/components/claude-code/version"
[ "$(_sb_claude_want "$FB")" = "latest" ] && ok "version file missing => latest" || bad "missing version file did not default to latest"
shipped="$(_sb_claude_want "$BASE")"
printf '%s' "$shipped" | grep -qxE 'latest|[0-9]+\.[0-9]+\.[0-9]+' \
  && ok "shipped components/claude-code/version parses (${shipped})" \
  || bad "shipped components/claude-code/version does not parse (${shipped})"

# ── 2. gates: kill-switch and refresh-only ─────────────────────────────────────
set_want latest; set_installed 2.1.267
run_step skip SKIP_CLAUDE_CODE_UPDATE=1
[ ! -e "$TMP/skip.calls" ] && [ -z "$(out skip)" ] \
  && ok "SKIP_CLAUDE_CODE_UPDATE=1 => no npm call, no output" || bad "kill-switch did not stop the step"

rm -f "$PKG/package.json"
run_step absent
{ out absent | grep -q 'not installed via npm' && ! called absent '^install' && ! called absent '^cache' && ! called absent '^view'; } \
  && ok "no npm-global install => skipped, never installs one (refresh-only)" \
  || bad "refresh-only gate failed ($(out absent))"

# ── 3. no-op when current ─────────────────────────────────────────────────────
set_want latest; set_installed 2.1.280
run_step current SB_T_LATEST=2.1.280
{ [ "$(out current)" = "claude code: 2.1.280 current" ] && ! called current '^install' && ! called current '^cache' && ! ran15b current; } \
  && ok "current => one status line, no download, no install, no 15b" \
  || bad "current path not a no-op ($(out current))"

# ── 4. behind => download first, install the exact version, 15b, one line ─────
set_want latest; set_installed 2.1.267
run_step behind SB_T_LATEST=2.1.280
[ "$(out behind)" = "claude code: 2.1.267 -> 2.1.280" ] \
  && ok "behind => stdout 'claude code: 2.1.267 -> 2.1.280'" || bad "behind: unexpected output ($(out behind))"
called behind 'cache add @anthropic-ai/claude-code@2.1.280 @anthropic-ai/claude-code-linux-x64@2.1.280' \
  && ok "download first: package + platform binary cached (live install untouched)" \
  || bad "prefetch did not cache the package and its linux-x64 binary"
cache_line="$(grep -n '^cache' "$TMP/behind.calls" | head -1 | cut -d: -f1)"
install_line="$(grep -n '^install' "$TMP/behind.calls" | head -1 | cut -d: -f1)"
[ -n "$cache_line" ] && [ -n "$install_line" ] && [ "$cache_line" -lt "$install_line" ] \
  && ok "the download happens before the in-place install" || bad "install ran before the download"
called behind 'install -g @anthropic-ai/claude-code@2.1.280 --prefer-offline' \
  && ok "installs the EXACT resolved version, served from the cache" || bad "install spec is not the exact version with --prefer-offline"
runs_as 2.1.280 && ok "the prefix-local binary now runs 2.1.280" || bad "binary does not report 2.1.280 after the upgrade"
{ ran15b behind && [ "$(seen)" = "2.1.280" ]; } \
  && ok "15b re-run after the upgrade (release notes stamped 2.1.280)" || bad "15b not re-run after the upgrade (seen=$(seen))"
[ "$(rc behind)" = 0 ] && ok "upgrade returns 0" || bad "upgrade returned $(rc behind)"

# ── 5. a pinned version holds (or rolls back) the fleet without asking npm ────
set_want 2.1.278; set_installed 2.1.280
run_step pinned
{ [ "$(out pinned)" = "claude code: 2.1.280 -> 2.1.278" ] && ! called pinned '^view' && runs_as 2.1.278; } \
  && ok "pinned version in the file => installed as-is, no registry lookup" \
  || bad "pinned version not applied ($(out pinned))"

# ── 6. registry unreachable / low disk => skipped, untouched, rc 0 ────────────
set_want latest; set_installed 2.1.267
run_step offline SB_T_REGISTRY_DOWN=1
{ out offline | grep -q 'could not resolve latest' && ! called offline '^install' && [ "$(rc offline)" = 0 ] && runs_as 2.1.267; } \
  && ok "registry unreachable => upgrade skipped, install untouched, rc 0" \
  || bad "registry-down path failed ($(out offline))"

set_want latest; set_installed 2.1.267
run_step lowdisk SB_T_FREE_MB=200
{ out lowdisk | grep -q 'low disk 200MB' && ! called lowdisk '^install' && ! called lowdisk '^cache' && runs_as 2.1.267; } \
  && ok "low disk => no download, no in-place install (partial-install guard)" \
  || bad "low-disk path failed ($(out lowdisk))"

# ── 7. a new version that does not run => reinstall once, then roll back ─────
set_want latest; set_installed 2.1.267
run_step rollback SB_T_LATEST=2.1.280 SB_T_BROKEN_VERSIONS=2.1.280
{ [ "$(out rollback)" = "claude code: upgrade to 2.1.280 FAILED — rolled back to 2.1.267" ] && [ "$(rc rollback)" = 0 ] && runs_as 2.1.267; } \
  && ok "broken new version => rolled back to the previous one, agent keeps a working claude" \
  || bad "rollback path failed ($(out rollback))"
[ "$(grep -c '^install -g @anthropic-ai/claude-code@2.1.280' "$TMP/rollback.calls")" = 2 ] \
  && ok "one clean reinstall is tried before the rollback" || bad "expected exactly two installs of the broken version"
[ "$(seen)" = "2.1.267" ] && ok "release notes stamp follows the rolled-back version" || bad "stamp not back on 2.1.267 (seen=$(seen))"

set_want latest; set_installed 2.1.267
run_step broken SB_T_LATEST=2.1.280 "SB_T_BROKEN_VERSIONS=2.1.280 2.1.267"
{ out broken | grep -q 'BROKEN after upgrade to 2.1.280' && [ "$(rc broken)" = 1 ]; } \
  && ok "no working version left => says BROKEN and returns 1" || bad "unrecoverable path failed ($(out broken))"

# ── 8. same version but the binary does not run => repaired by reinstall ──────
set_want latest; set_installed 2.1.280; : > "$PREFIX/broken"
run_step repair SB_T_LATEST=2.1.280
{ [ "$(out repair)" = "claude code: 2.1.280 repaired" ] && runs_as 2.1.280 && [ "$(rc repair)" = 0 ]; } \
  && ok "installed == target but not running => reinstalled, reported as repaired" \
  || bad "repair path failed ($(out repair))"

# ── 9. an upgrade done elsewhere => 15b catches up, nothing reinstalled ───────
set_want latest; set_installed 2.1.280 2.1.267
run_step stale SB_T_LATEST=2.1.280
{ [ "$(out stale)" = "claude code: 2.1.280 current" ] && ran15b stale && [ "$(seen)" = "2.1.280" ] && ! called stale '^install'; } \
  && ok "stale release-notes stamp => 15b re-run without a reinstall" \
  || bad "stale-stamp path failed ($(out stale), seen=$(seen))"

# ── 10. wiring: runs on EVERY sb_refresh_base_artifacts call, gate or not ──────
# An agent's installed wrapper predates this step and only calls
# sb_refresh_base_artifacts, so the step must run even when the base-artifact
# fingerprint says "current" — otherwise it lands one self-update late.
: > "$FB/refresh-manifest.txt"
FP="$(sb_base_artifacts_fingerprint "$FB")"
{ echo "runners_ref=main"; echo "base_artifacts_sha=$FP"; } > "$SB_UPDATED_MARKER"
set_want latest; set_installed 2.1.267
WIRED="$(
  export PATH="$CC/stub:$PATH" SB_T_PREFIX="$PREFIX" SB_T_LATEST=2.1.280 \
         SB_T_CALLS="$TMP/wired.calls" SB_T_15B_CALLS="$TMP/wired.15b"
  sb_refresh_base_artifacts "$FB" main 2>/dev/null
)"
{ printf '%s\n' "$WIRED" | grep -qx 'claude code: 2.1.267 -> 2.1.280' \
  && printf '%s\n' "$WIRED" | grep -q '^base artifacts: already current'; } \
  && ok "sb_refresh_base_artifacts runs the Claude Code step even when the fingerprint gate is current" \
  || bad "Claude Code step not reached through sb_refresh_base_artifacts ($WIRED)"
claude_line="$(grep -n 'sb_refresh_claude_code "\$base"' "$BASE/lib-refresh.sh" | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'if sb_artifacts_current "\$fp" "\$ref"' "$BASE/lib-refresh.sh" | head -1 | cut -d: -f1)"
[ -n "$claude_line" ] && [ -n "$gate_line" ] && [ "$claude_line" -lt "$gate_line" ] \
  && ok "the call sits above the fingerprint gate in lib-refresh.sh" || bad "the Claude Code call is not above the fingerprint gate"

# ── 11. never a PATH lookup, never a service restart ──────────────────────────
body="$(sed -n '/^sb_refresh_claude_code()/,/^}/p; /^_sb_claude_runs()/,/^}/p' "$BASE/lib-refresh.sh")"
printf '%s\n' "$body" | grep -q 'command -v claude' \
  && bad "the step resolves claude on PATH (must stay prefix-local)" || ok "health checks are prefix-local (no 'command -v claude')"
printf '%s\n' "$body" | grep -qE 'systemctl (restart|stop)' \
  && bad "the step restarts a service (it runs inside a job)" || ok "the step never restarts sidebutton.service"

# ── 12. the sibling guard cannot upgrade a real Claude Code ───────────────────
grep -q '^export SKIP_CLAUDE_CODE_UPDATE=1' "$SCRIPT_DIR/test-sb-self-update.sh" \
  && ok "test-sb-self-update.sh keeps the Claude Code step off" \
  || bad "test-sb-self-update.sh calls sb_refresh_base_artifacts without SKIP_CLAUDE_CODE_UPDATE=1"

# ── 13. syntax ─────────────────────────────────────────────────────────────────
for f in lib-refresh.sh assets/sb-self-update.sh components/claude-code/install.sh; do
  bash -n "$BASE/$f" 2>/dev/null && ok "bash -n: $f" || bad "bash -n failed: $f"
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
