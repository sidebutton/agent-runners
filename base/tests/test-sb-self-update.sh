#!/usr/bin/env bash
# base/tests/test-sb-self-update.sh — regression guard for SCRUM-1380.
#
# sb-self-update was widened from an npm-only updater into the fleet's base-artifact
# refresh path. The risky, reusable parts live in base/lib-refresh.sh:
#   - the manifest drives WHICH steps re-run (no more hard-coded subset that drops
#     newly added steps),
#   - a fingerprint change-gates the work (a no-change tick must be a true no-op),
#   - the Claude hooks block is re-merged preserving every other settings key.
# This test exercises those pure pieces without root/systemd, plus `bash -n` on the
# wrapper + the modified steps. Pure bash + jq (both present on the runner).
# Run: bash base/tests/test-sb-self-update.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate side-effecting paths to the sandbox before sourcing the lib.
export SB_UPDATED_MARKER="$TMP/updated"
export SB_SELF_UPDATE_BIN="$TMP/sb-self-update.bin"
export AGENT_USER="$(id -un)"
export AGENT_HOME="$TMP/home"
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.local/bin"  # base/09 makes these in prod

# Keep the catalog ops-pack refresh (sb_refresh_knowledge_packs, called inside
# sb_refresh_base_artifacts) inert for the base-artifact sections — otherwise, on a
# machine that happens to have the `sidebutton` CLI, it would hit the network and
# write the real ~/.sidebutton. Section 4c re-enables it against a local stub.
export SKIP_KNOWLEDGE_PACKS=1

# shellcheck source=../lib-refresh.sh
. "$BASE/lib-refresh.sh"

# ── 1. manifest parsing + integrity ──────────────────────────────────────────
mapfile -t STEPS < <(sb_refresh_manifest_files "$BASE")
if [ "${#STEPS[@]}" -ge 5 ]; then ok "manifest lists ${#STEPS[@]} steps"; else bad "manifest returned too few steps (${#STEPS[@]})"; fi

manifest_clean=1
for s in "${STEPS[@]}"; do
  case "$s" in \#*|"") manifest_clean=0 ;; esac
  [ -f "$BASE/$s" ] || { bad "manifest step missing in tree: $s"; manifest_clean=0; }
done
[ "$manifest_clean" = 1 ] && ok "manifest entries are clean and all exist in base/"

# The step that motivated the manifest (added after the old hard-coded list) must
# be covered, and unsafe steps must NOT be.
printf '%s\n' "${STEPS[@]}" | grep -qx '18c-git-telemetry-timer.sh' \
  && ok "manifest covers 18c-git-telemetry-timer.sh (the silently-dropped step)" \
  || bad "manifest is missing 18c-git-telemetry-timer.sh"
# 19e-session-tidy.sh (SCRUM-1769) reaches the live fleet ONLY via this manifest — it is the
# whole deployment path for the fix (no re-provisioning), so a dropped entry means boxes keep
# accumulating finished Claude TUIs until they OOM-livelock, silently.
printf '%s\n' "${STEPS[@]}" | grep -qx '19e-session-tidy.sh' \
  && ok "manifest covers 19e-session-tidy.sh (session-tidy's only fleet path)" \
  || bad "manifest is missing 19e-session-tidy.sh"
if printf '%s\n' "${STEPS[@]}" | grep -qE '^(19-secrets|18-heartbeat|20-mark-installed)\.sh$'; then
  bad "manifest must NOT include token-rotating / re-registering / lifecycle steps"
else
  ok "manifest excludes the unsafe-to-rerun steps"
fi

# ── 2. fingerprint: deterministic, hex, and change-sensitive ─────────────────
FP1="$(sb_base_artifacts_fingerprint "$BASE")"
FP2="$(sb_base_artifacts_fingerprint "$BASE")"
[ -n "$FP1" ] && [ "$FP1" = "$FP2" ] && ok "fingerprint is deterministic" || bad "fingerprint not deterministic ($FP1 vs $FP2)"
printf '%s' "$FP1" | grep -qE '^[0-9a-f]{64}$' && ok "fingerprint is a sha256 hex digest" || bad "fingerprint not a sha256 ($FP1)"

# Mutating a tracked artifact in a copied tree must flip the fingerprint.
cp -a "$BASE" "$TMP/tree"
printf '\n# drift\n' >> "$TMP/tree/assets/claude-hooks.json"
FP_DRIFT="$(sb_base_artifacts_fingerprint "$TMP/tree")"
[ "$FP_DRIFT" != "$FP1" ] && ok "fingerprint changes when a tracked artifact changes" || bad "fingerprint did not change on drift"

# ── 3. change-gate (sb_artifacts_current) ────────────────────────────────────
sb_artifacts_current "$FP1" "main" "$TMP/none" && bad "current returned true with no marker" || ok "no marker => not current (refresh would run)"
{ echo "runners_ref=main"; echo "base_artifacts_sha=$FP1"; } > "$TMP/m"
sb_artifacts_current "$FP1" "main" "$TMP/m" && ok "matching fp+ref => current (no-op)" || bad "matching marker not detected as current"
sb_artifacts_current "deadbeef" "main" "$TMP/m" && bad "stale fp wrongly reported current" || ok "changed fp => not current"
sb_artifacts_current "$FP1" "other-ref" "$TMP/m" && bad "changed ref wrongly reported current" || ok "changed ref => not current"

# ── 4. no-op apply path: a matching marker must skip work entirely ────────────
# (Safe to run as non-root: the early return happens before any step executes or
# the wrapper is reinstalled.)
{ echo "runners_ref=main"; echo "base_artifacts_sha=$FP1"; } > "$SB_UPDATED_MARKER"
OUT="$(sb_refresh_base_artifacts "$BASE" "main" 2>/dev/null)"
if echo "$OUT" | grep -q 'already current' && [ ! -e "$SB_SELF_UPDATE_BIN" ]; then
  ok "unchanged fingerprint => apply is a true no-op (no wrapper reinstall, no steps)"
else
  bad "no-op gate did not short-circuit (out='$OUT')"
fi

# An unusable tree (no manifest) must fail cleanly without writing a marker.
rm -f "$SB_UPDATED_MARKER"
mkdir -p "$TMP/emptytree"
if sb_refresh_base_artifacts "$TMP/emptytree" "main" >/dev/null 2>&1; then
  bad "apply on a manifest-less tree should return non-zero"
else
  [ ! -e "$SB_UPDATED_MARKER" ] && ok "manifest-less tree => clean failure, no marker written" || bad "marker written despite unusable tree"
fi

# ── 4b. proceed path: a fingerprint change runs the manifest steps + records ──
# Sandboxed fake tree with stub steps so we can exercise the full orchestration
# (env contract -> steps run, wrapper reinstall, marker write) without root/systemd.
FT="$TMP/tree-proceed"
mkdir -p "$FT/base/assets"
cp "$BASE/lib.sh" "$BASE/lib-refresh.sh" "$FT/base/"
cp "$BASE/assets/claude-hooks.json" "$BASE/assets/sb-self-update.sh" "$FT/base/assets/"
printf 'stepA.sh\nstepB.sh\n' > "$FT/base/refresh-manifest.txt"
echo 'step "stub A"; : > "$AGENT_HOME/.local/bin/ran-A"' > "$FT/base/stepA.sh"
echo 'step "stub B"; : > "$AGENT_HOME/.local/bin/ran-B"' > "$FT/base/stepB.sh"
echo '{"mcpServers":{"x":{}},"hooks":{"Stop":[]}}' > "$AGENT_HOME/.claude/settings.json"
rm -f "$SB_UPDATED_MARKER" "$SB_SELF_UPDATE_BIN"
( export LOG_FILE="$TMP/refresh.log"
  . "$FT/base/lib.sh"; . "$FT/base/lib-refresh.sh"
  sb_refresh_base_artifacts "$FT/base" "fix/test-ref" ) >/dev/null 2>&1
[ -f "$AGENT_HOME/.local/bin/ran-A" ] && [ -f "$AGENT_HOME/.local/bin/ran-B" ] \
  && ok "proceed path runs every manifest step with the BASE_DIR/AGENT_HOME contract" \
  || bad "proceed path did not run the manifest steps"
[ -f "$SB_SELF_UPDATE_BIN" ] && cmp -s "$FT/base/assets/sb-self-update.sh" "$SB_SELF_UPDATE_BIN" \
  && ok "proceed path self-reinstalls the wrapper" || bad "proceed path did not reinstall the wrapper"
grep -q '^runners_ref=fix/test-ref$' "$SB_UPDATED_MARKER" 2>/dev/null \
  && grep -qE '^base_artifacts_sha=[0-9a-f]{64}$' "$SB_UPDATED_MARKER" 2>/dev/null \
  && ok "proceed path records the effective ref + fingerprint marker" || bad "marker not written correctly"

# ── 4c. catalog ops-pack refresh: version-compare change-gate (no network) ────
# Stub `sidebutton` so the PLAIN install's exit code drives force-vs-skip without
# touching the catalog: rc 0 = already current, rc 1 = "Use --force" refusal. The
# stub records its args so we can assert whether --force was issued.
PKGBIN="$TMP/pkgbin"; mkdir -p "$PKGBIN"
cat > "$PKGBIN/sidebutton" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB_STUB_CALLS"
case "$*" in
  *--force*)        exit 0 ;;                      # force always succeeds
  "install agents") exit "${SB_STUB_PLAIN_RC:-0}" ;;
  *)                exit 0 ;;
esac
STUB
chmod +x "$PKGBIN/sidebutton"
mkdir -p "$AGENT_HOME/.sidebutton/skills/agents"  # agent HAS the pack (refresh-only gate)

# A: plain install succeeds (already current) => no --force, status "current".
( export PATH="$PKGBIN:$PATH" SB_STUB_CALLS="$TMP/callsA" SB_STUB_PLAIN_RC=0
  unset SKIP_KNOWLEDGE_PACKS
  out="$(sb_refresh_knowledge_packs agents 2>/dev/null)"
  echo "$out" | grep -q 'agents current' || exit 1
  ! grep -q -- '--force' "$TMP/callsA" ) \
  && ok "pack refresh: unchanged version => no --force (true no-op)" \
  || bad "pack refresh no-op gate failed"

# B: plain install refuses (drift, rc 1) => helper forces, status "refreshed".
( export PATH="$PKGBIN:$PATH" SB_STUB_CALLS="$TMP/callsB" SB_STUB_PLAIN_RC=1
  unset SKIP_KNOWLEDGE_PACKS
  out="$(sb_refresh_knowledge_packs agents 2>/dev/null)"
  echo "$out" | grep -q 'agents refreshed' || exit 1
  grep -qx 'install agents --force' "$TMP/callsB" ) \
  && ok "pack refresh: version drift => converges via --force" \
  || bad "pack refresh force-on-drift failed"

# C: SKIP_KNOWLEDGE_PACKS=1 => never even invokes the CLI.
( export PATH="$PKGBIN:$PATH" SB_STUB_CALLS="$TMP/callsC" SKIP_KNOWLEDGE_PACKS=1
  out="$(sb_refresh_knowledge_packs agents 2>/dev/null)"
  [ -z "$out" ] && [ ! -s "$TMP/callsC" ] ) \
  && ok "pack refresh: SKIP_KNOWLEDGE_PACKS=1 => no install attempted" \
  || bad "pack refresh SKIP gate failed"

# D: a pack NOT installed on this agent => never fresh-install (respect provisioning).
( export PATH="$PKGBIN:$PATH" SB_STUB_CALLS="$TMP/callsD"
  unset SKIP_KNOWLEDGE_PACKS
  out="$(sb_refresh_knowledge_packs neverinstalled 2>/dev/null)"
  [ -z "$out" ] && [ ! -s "$TMP/callsD" ] ) \
  && ok "pack refresh: pack not installed => no fresh-install (respects provisioning)" \
  || bad "pack refresh not-installed gate failed"

# ── 4d. sb_refresh_server_cli: latch fix + disk preflight + verify/repair ─────
# Exercises the hardened CLI upgrade with stubbed npm/sidebutton/systemctl/df/curl
# (no root, no network). Guards the three defects behind the ENOSPC brick (RCA
# 2026-06-28): the server-variant gate is the UNIT (not `command -v sidebutton`), a
# low disk skips the in-place install, and a stranded bin link is repaired by relink.
SRV="$TMP/srv"
mkdir -p "$SRV/stub" "$SRV/prefix/bin" "$SRV/prefix/lib/node_modules/sidebutton/bin"
cat > "$SRV/prefix/lib/node_modules/sidebutton/package.json" <<'JSON'
{ "name": "sidebutton", "version": "9.9.9", "bin": { "sidebutton": "./bin/sidebutton.js" } }
JSON
cat > "$SRV/prefix/lib/node_modules/sidebutton/bin/sidebutton.js" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
let v = '9.9.9';
try { v = fs.readFileSync(process.env.SB_T_VERFILE, 'utf8').trim(); } catch (e) {}
console.log(v);
JS
chmod +x "$SRV/prefix/lib/node_modules/sidebutton/bin/sidebutton.js"

cat > "$SRV/stub/systemctl" <<'ST'
#!/usr/bin/env bash
case "$*" in
  "list-unit-files sidebutton.service --no-legend")
     [ "${SB_T_HAVE_UNIT:-1}" = 1 ] && echo "sidebutton.service enabled enabled" || true ;;
  "restart sidebutton") echo restart >> "${SB_T_CALLS:-/dev/null}" ;;
esac
ST
cat > "$SRV/stub/npm" <<'ST'
#!/usr/bin/env bash
case "$*" in
  "prefix -g") printf '%s\n' "$SB_T_PREFIX" ;;
  "install -g sidebutton@latest")
     echo npm-install >> "${SB_T_CALLS:-/dev/null}"
     [ "${SB_T_NPM_BREAKS:-0}" = 1 ] && rm -f "$SB_T_PREFIX/bin/sidebutton"
     [ "${SB_T_BUMP:-0}" = 1 ] && echo 9.9.10 > "$SB_T_VERFILE" ;;
esac
exit 0
ST
cat > "$SRV/stub/df" <<'ST'
#!/usr/bin/env bash
echo "Filesystem 1M-blocks Used Avail Cap Mounted"
echo "/dev/root 38000 1000 ${SB_T_FREE_MB:-30000} 5% /"
ST
cat > "$SRV/stub/curl" <<'ST'
#!/usr/bin/env bash
exit 0
ST
chmod +x "$SRV"/stub/*

VERFILE="$SRV/ver"
srv_path="$SRV/stub:$SRV/prefix/bin:$PATH"
relink_initial() { ln -sfn ../lib/node_modules/sidebutton/bin/sidebutton.js "$SRV/prefix/bin/sidebutton"; }

# A: serverless (no unit) => skip, npm install never invoked (latch fix: gate=unit).
relink_initial; echo 9.9.9 > "$VERFILE"
( export PATH="$srv_path" SB_T_PREFIX="$SRV/prefix" SB_T_VERFILE="$VERFILE" \
         SB_T_HAVE_UNIT=0 SB_T_CALLS="$TMP/srvA"
  out="$(sb_refresh_server_cli 2>&1)"; echo "$out" | grep -qi serverless ) \
  && [ ! -e "$TMP/srvA" ] \
  && ok "server CLI: no sidebutton.service => skipped, no npm install (unit-gated, not command -v)" \
  || bad "server CLI serverless gate failed"

# B: server box but low disk => skip the in-place install entirely (corruption guard).
relink_initial; echo 9.9.9 > "$VERFILE"
( export PATH="$srv_path" SB_T_PREFIX="$SRV/prefix" SB_T_VERFILE="$VERFILE" \
         SB_T_HAVE_UNIT=1 SB_T_FREE_MB=200 SB_T_CALLS="$TMP/srvB"
  out="$(sb_refresh_server_cli 2>&1)"; echo "$out" | grep -qi 'low disk' ) \
  && [ ! -e "$TMP/srvB" ] \
  && ok "server CLI: low disk => npm upgrade skipped (no partial install)" \
  || bad "server CLI disk-preflight failed"

# C: healthy install, version unchanged => installs but does NOT restart.
relink_initial; echo 9.9.9 > "$VERFILE"
( export PATH="$srv_path" SB_T_PREFIX="$SRV/prefix" SB_T_VERFILE="$VERFILE" \
         SB_T_HAVE_UNIT=1 SB_T_FREE_MB=30000 SB_T_CALLS="$TMP/srvC"
  out="$(sb_refresh_server_cli 2>&1)"; echo "$out" | grep -qi current ) \
  && grep -qx npm-install "$TMP/srvC" && ! grep -qx restart "$TMP/srvC" \
  && ok "server CLI: same version => no needless restart" \
  || bad "server CLI no-change path failed"

# D: healthy install, version changes => restart issued.
relink_initial; echo 9.9.9 > "$VERFILE"
( export PATH="$srv_path" SB_T_PREFIX="$SRV/prefix" SB_T_VERFILE="$VERFILE" \
         SB_T_HAVE_UNIT=1 SB_T_FREE_MB=30000 SB_T_BUMP=1 SB_T_CALLS="$TMP/srvD"
  sb_refresh_server_cli >/dev/null 2>&1 )
grep -qx restart "$TMP/srvD" 2>/dev/null \
  && ok "server CLI: healthy version change => restart" \
  || bad "server CLI restart-on-change failed"

# E: npm strands the bin link (the ENOSPC brick) => relink repairs it, rc 0, no
# "BROKEN", and the bin link is present again (self-heal, no manual fix).
relink_initial; echo 9.9.9 > "$VERFILE"
( export PATH="$srv_path" SB_T_PREFIX="$SRV/prefix" SB_T_VERFILE="$VERFILE" \
         SB_T_HAVE_UNIT=1 SB_T_FREE_MB=30000 SB_T_NPM_BREAKS=1 SB_T_CALLS="$TMP/srvE"
  out="$(sb_refresh_server_cli 2>&1)"; rc=$?
  [ "$rc" = 0 ] && ! echo "$out" | grep -qi broken ) \
  && [ -e "$SRV/prefix/bin/sidebutton" ] \
  && ok "server CLI: stranded bin link => repaired by relink (self-heal)" \
  || bad "server CLI repair path failed"

# ── 5. Claude hooks re-merge preserves other keys, replaces .hooks ───────────
cat > "$AGENT_HOME/.claude/settings.json" <<'JSON'
{ "mcpServers": {"sidebutton": {"command": "sidebutton"}},
  "env": {"KEEP": "me"},
  "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "OLD"}]}]} }
JSON
HSTATUS="$(_sb_merge_claude_hooks "$BASE/assets/claude-hooks.json")"
if jq -e '.mcpServers.sidebutton and .env.KEEP == "me"' "$AGENT_HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "hooks merge preserves mcpServers + env"
else
  bad "hooks merge clobbered non-hook keys"
fi
if jq -e --slurpfile h "$BASE/assets/claude-hooks.json" '.hooks == $h[0].hooks' "$AGENT_HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "hooks merge installs the canonical hooks block ($HSTATUS)"
else
  bad "hooks block not replaced with the canonical asset"
fi
HSTATUS2="$(_sb_merge_claude_hooks "$BASE/assets/claude-hooks.json")"
[ "$HSTATUS2" = "unchanged" ] && ok "re-merge is idempotent (status unchanged)" || bad "re-merge not idempotent ($HSTATUS2)"

# ── 6. shell syntax of the wrapper + everything it / the markers touch ────────
for f in lib-refresh.sh assets/sb-self-update.sh 08-sidebutton.sh 18-heartbeat.sh \
         18b-heartbeat-timer.sh 20-mark-installed.sh; do
  bash -n "$BASE/$f" 2>/dev/null && ok "bash -n: $f" || bad "bash -n failed: $f"
done
head -1 "$BASE/assets/sb-self-update.sh" | grep -q '^#!' && ok "wrapper asset has a shebang" || bad "wrapper asset missing shebang"
[ -x "$BASE/assets/sb-self-update.sh" ] && ok "wrapper asset is executable" || bad "wrapper asset not executable"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
