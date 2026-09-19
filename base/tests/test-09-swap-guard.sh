#!/usr/bin/env bash
# base/tests/test-09-swap-guard.sh — regression guard for the step-9 swap block.
#
# THE BUG: base/09 created a 4 GB /swapfile with an UNGUARDED
#     fallocate -l 4G /swapfile ; mkswap /swapfile ; swapon /swapfile
# run.sh is `set -euo pipefail` and every step is SOURCED into that same shell, so
# either command failing killed the ENTIRE install at step 9 of 16 — before the
# desktop, before the SB server, before the first heartbeat, i.e. the agent never
# even appeared in the portal. Two real ways that happens:
#   - in a CONTAINER: overlayfs `fallocate` returns EOPNOTSUPP, and `swapon` is a
#     kernel-GLOBAL operation a container must not perform anyway (found 2026-09-19
#     running the documented BYO installer in Docker on WSL2);
#   - on a host filesystem that cannot fallocate (ZFS, some network mounts).
#
# What this proves, in rough order of how much it would hurt to get wrong:
#   1. A FAILING fallocate does not abort a `set -euo pipefail` shell. This is the
#      whole point of the fix, and it is why the block is EXECUTED here rather than
#      pattern-matched: a grep for the guard passes happily on code that still
#      aborts one line further down.
#   2. A container is detected and the block is SKIPPED ENTIRELY — fallocate is
#      never invoked, swapon is never invoked.
#   3. The happy path still creates swap and still writes the fstab entry. The fix
#      must not quietly stop making swap on the hosts where it always worked.
#   4. An existing /swapfile is left alone (the original block's one good property).
#   5. The `swap:` log line survives on every path — it is what a provision log
#      gets read for when someone asks whether the box got swap.
#
# Hermetic: pure bash, no root, no systemd. The block is extracted from the real
# step and every absolute path it touches (/swapfile, /etc/fstab, /.dockerenv) is
# rewritten into a temp dir, with fallocate/mkswap/swapon/free/systemd-detect-virt
# as PATH stubs — so the test can never touch the real machine's swap.
# Run: bash base/tests/test-09-swap-guard.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="$SCRIPT_DIR/../09-agent-user.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Extract the swap block and re-root every absolute path into $TMP ──────────
# Anchored on the section comment and the trailing `log "swap:` line; if either
# marker moves the extraction comes back empty and the guard fails loudly, which
# is intended — this test is pinned to a specific block.
BLOCK="$(sed -n '/^# Swap/,/^log "swap:/p' "$STEP")"
if [ -z "$BLOCK" ]; then
  bad "could not extract the swap block from 09-agent-user.sh (markers moved?)"
  exit 1
fi
ok "swap block extracted from the real step script"

BLOCK="${BLOCK//\/swapfile/$TMP\/swapfile}"
BLOCK="${BLOCK//\/etc\/fstab/$TMP\/fstab}"
BLOCK="${BLOCK//\/.dockerenv/$TMP\/dockerenv}"

# ── PATH stubs. Each records its invocation so we can assert what was NOT run. ─
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemd-detect-virt" <<STUB
#!/usr/bin/env bash
echo "systemd-detect-virt \$*" >> "$TMP/calls"
if [ "\${STUB_VIRT_RC:-1}" = "0" ]; then echo docker; exit 0; fi
echo none
exit 1
STUB
cat > "$TMP/bin/fallocate" <<STUB
#!/usr/bin/env bash
echo "fallocate \$*" >> "$TMP/calls"
if [ "\${STUB_FALLOCATE_RC:-0}" != "0" ]; then exit 1; fi
: > "$TMP/swapfile"
STUB
cat > "$TMP/bin/mkswap" <<STUB
#!/usr/bin/env bash
echo "mkswap \$*" >> "$TMP/calls"
exit "\${STUB_MKSWAP_RC:-0}"
STUB
cat > "$TMP/bin/swapon" <<STUB
#!/usr/bin/env bash
echo "swapon \$*" >> "$TMP/calls"
exit "\${STUB_SWAPON_RC:-0}"
STUB
cat > "$TMP/bin/free" <<STUB
#!/usr/bin/env bash
printf '              total\nSwap:          4.0Gi\n'
STUB
chmod +x "$TMP/bin/"*

# ── Harness: run the block exactly as run.sh would — under set -euo pipefail ──
{
  echo 'set -euo pipefail'
  echo "log() { printf '%s\\n' \"\$*\" >> \"$TMP/log\"; }"
  printf '%s\n' "$BLOCK"
} > "$TMP/harness.sh"

reset_tmp() {
  rm -f "$TMP/calls" "$TMP/log" "$TMP/fstab" "$TMP/swapfile" "$TMP/dockerenv"
  touch "$TMP/calls" "$TMP/log" "$TMP/fstab"
}
# run <VAR=VAL...> — executes the block, returns its exit code.
run() {
  env PATH="$TMP/bin:$PATH" "$@" bash "$TMP/harness.sh" >/dev/null 2>&1
}
called() { grep -q "^$1" "$TMP/calls"; }
logged() { grep -q "$1" "$TMP/log"; }

# ── 1. THE REGRESSION: fallocate fails on a real host → must NOT abort ────────
reset_tmp
run STUB_VIRT_RC=1 STUB_FALLOCATE_RC=1
rc=$?
if [ "$rc" = "0" ]; then
  ok "failing fallocate does not abort a set -euo pipefail shell (exit 0)"
else
  bad "failing fallocate aborted the shell (exit $rc) — THE BUG IS BACK"
fi
if logged "WARN"; then ok "failing fallocate logs a WARN instead of dying silently"
else bad "no WARN logged when fallocate failed"; fi
if called swapon; then bad "swapon was called after fallocate failed"
else ok "swapon not attempted after fallocate failed"; fi

# ── 2. Container → skipped entirely ──────────────────────────────────────────
reset_tmp
run STUB_VIRT_RC=0
rc=$?
if [ "$rc" = "0" ]; then ok "container path exits 0"; else bad "container path exited $rc"; fi
if called fallocate; then bad "fallocate called inside a container"
else ok "container: fallocate never invoked"; fi
if called swapon; then bad "swapon called inside a container — kernel-global op"
else ok "container: swapon never invoked"; fi
if logged "skipped (container"; then ok "container path says WHY it skipped"
else bad "container path did not log the skip reason"; fi

# ── 2b. /.dockerenv alone is enough (systemd-detect-virt may be absent) ───────
reset_tmp
touch "$TMP/dockerenv"
run STUB_VIRT_RC=1
rc=$?
if [ "$rc" = "0" ] && ! called fallocate; then
  ok "/.dockerenv alone is enough to skip (systemd-detect-virt may be absent)"
else
  bad "/.dockerenv did not suppress the swap block (exit $rc)"
fi

# ── 3. Happy path still creates swap + the fstab entry ───────────────────────
reset_tmp
run STUB_VIRT_RC=1
rc=$?
if [ "$rc" = "0" ]; then ok "happy path exits 0"; else bad "happy path exited $rc"; fi
if called fallocate && called mkswap && called swapon; then
  ok "happy path still runs fallocate + mkswap + swapon"
else
  bad "happy path no longer creates swap — the fix broke the working hosts"
fi
# The fstab line the block writes names the swapfile, so it carries the rewritten
# $TMP path here too — match it as a fixed string, not as the literal "/swapfile".
if grep -Fq "$TMP/swapfile none swap sw 0 0" "$TMP/fstab" 2>/dev/null; then
  ok "happy path persists the fstab entry (swap survives reboot)"
else
  bad "fstab entry not written on the happy path"
fi

# ── 3b. swapon fails late → tolerated, and the dead file is cleaned up ────────
reset_tmp
run STUB_VIRT_RC=1 STUB_SWAPON_RC=1
rc=$?
if [ "$rc" = "0" ]; then ok "a failing swapon is tolerated too"
else bad "failing swapon aborted the shell (exit $rc)"; fi
if [ -e "$TMP/swapfile" ]; then bad "a 4 GB file was left behind after swapon failed"
else ok "the unusable swapfile is removed, not left wasting disk"; fi

# ── 4. Pre-existing swapfile is left alone ───────────────────────────────────
reset_tmp
touch "$TMP/swapfile"
run STUB_VIRT_RC=1
rc=$?
if [ "$rc" = "0" ] && ! called fallocate && ! called swapon; then
  ok "an existing /swapfile is left untouched"
else
  bad "an existing /swapfile was re-created or re-swapped on (exit $rc)"
fi

# ── 5. The observable survives on every path ─────────────────────────────────
missing=0
for s in "STUB_VIRT_RC=0" "STUB_VIRT_RC=1" "STUB_FALLOCATE_RC=1"; do
  reset_tmp
  run STUB_VIRT_RC=1 "$s"
  logged "swap:" || { bad "no 'swap:' line logged for scenario [$s]"; missing=1; }
done
[ "$missing" = "0" ] && ok "every path still logs the 'swap:' line a provision log is read for"

if [ "$fail" = "0" ]; then printf '\nSUITE GREEN\n'; else printf '\nSUITE RED\n'; fi
exit "$fail"
