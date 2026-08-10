#!/usr/bin/env bash
# base/tests/test-19g-agent-reboot.sh — regression guard for agent reboot (SCRUM-1926).
#
# Both portal reboot lanes reported success while the VM stayed up. The half of that
# bug this repo owns: the agent user could not reboot its own box. Its sudoers granted
# exactly two wrappers (sb-self-update, sb-config-place) and it is in no sudo group, so
# the daemon's `sudo reboot` was denied on every provisioned agent — journal-proven,
# `agent : command not allowed ; COMMAND=/usr/sbin/reboot` — while the daemon answered
# {"ok":true}. base/19g installs the missing privileged path (sb-reboot + a narrow
# NOPASSWD rule) and a logind drop-in so a soft ACPI press is no longer swallowed by
# lightdm's unity-greeter.
#
# What this proves, in rough order of how much it would hurt to get wrong:
#   1. RISK #1 — the step reaches the EXISTING fleet. 19g must be in refresh-manifest.txt
#      AND its asset must be in the fingerprint's asset list. Miss either and the fix
#      silently ships to new agents only: exactly the failure mode SCRUM-1380 exists to
#      prevent, and indistinguishable from "fixed" in review.
#   2. The sudo grant stays NARROW. A drift to `ALL=(ALL) NOPASSWD: ALL` would "fix" the
#      ticket while handing the agent user root over the whole box.
#   3. The wrapper reboots via systemd, not via the ACPI/power-key path that the greeter's
#      block inhibitor swallows — that mechanism choice IS the fix, not a style call.
#   4. The wrapper reports a real exit code (it is what lets the daemon stop lying), and
#      the sudoers file is only written when the wrapper actually installed.
#
# Hermetic: pure bash, no root, no systemd — it reads the shipped scripts and exercises
# the real fingerprint function from lib-refresh.sh in a temp tree.
# Run: bash base/tests/test-19g-agent-reboot.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/19g-agent-reboot.sh"
WRAPPER="$BASE/assets/sb-reboot.sh"
MANIFEST="$BASE/refresh-manifest.txt"
RUN="$BASE/run.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Comment-stripped views of the two files under test.
#
# Both scripts carry long prose headers that name the very strings these assertions look
# for ("systemctl reboot --no-block", "PowerKeyIgnoreInhibited=yes", the drop-in path).
# Grepping the raw file therefore passes on the strength of the COMMENT, so a mutation
# that guts the code — swapping the reboot mechanism, dropping the load-bearing logind
# option — still goes green. A test whose central assertions cannot fail is worse than no
# test: it is a review signal that reads as coverage. Assert against code only.
STEP_CODE="$TMP/19g.code.sh"
WRAPPER_CODE="$TMP/sb-reboot.code.sh"
sed 's/^[[:space:]]*#.*$//' "$STEP"    > "$STEP_CODE"
sed 's/^[[:space:]]*#.*$//' "$WRAPPER" > "$WRAPPER_CODE"

# ── 0. the files exist and parse ─────────────────────────────────────────────
[ -f "$STEP" ]    && ok "base/19g-agent-reboot.sh exists"     || bad "base/19g-agent-reboot.sh missing"
[ -f "$WRAPPER" ] && ok "base/assets/sb-reboot.sh exists"     || bad "base/assets/sb-reboot.sh missing"
bash -n "$STEP"    2>/dev/null && ok "19g parses"      || bad "19g has a syntax error"
bash -n "$WRAPPER" 2>/dev/null && ok "sb-reboot parses" || bad "sb-reboot has a syntax error"

# ── 1. RISK #1: the fix reaches the live fleet ───────────────────────────────
# base/08 and base/09 (which own the other sudoers grants and the agent user) are
# provision-only — 01..13 are never re-run — so a grant added there would reach NEW
# agents only. The manifest is the whole deployment path for existing boxes.
grep -qx '19g-agent-reboot.sh' "$MANIFEST" \
  && ok "refresh-manifest lists 19g (fix reaches the existing fleet)" \
  || bad "refresh-manifest is missing 19g — the fix would reach new agents only"

grep -q '19g-agent-reboot.sh' "$RUN" \
  && ok "run.sh sources 19g (fix reaches newly provisioned agents)" \
  || bad "run.sh does not source 19g — new agents would not get sb-reboot"

# The wrapper is an ASSET the step copies, so an edit to it leaves 19g's own bytes
# unchanged. Unless the asset is in the fingerprint's explicit list, a wrapper-only
# fix would be change-gated OUT and the fleet would keep running the old copy (the
# same trap documented for report-health-snapshot.sh in SCRUM-1626).
export SB_UPDATED_MARKER="$TMP/updated"
export SB_SELF_UPDATE_BIN="$TMP/sb-self-update.bin"
export AGENT_USER="$(id -un)"
export AGENT_HOME="$TMP/home"
export SKIP_KNOWLEDGE_PACKS=1
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.local/bin"
# shellcheck source=../lib-refresh.sh
. "$BASE/lib-refresh.sh"

cp -r "$BASE" "$TMP/tree"
FP_BASE="$(sb_base_artifacts_fingerprint "$TMP/tree")"
printf '\n# drift\n' >> "$TMP/tree/assets/sb-reboot.sh"
FP_DRIFT="$(sb_base_artifacts_fingerprint "$TMP/tree")"
[ -n "$FP_BASE" ] && [ "$FP_DRIFT" != "$FP_BASE" ] \
  && ok "a sb-reboot-only edit flips the refresh fingerprint" \
  || bad "sb-reboot is not in the fingerprint — a wrapper-only fix would never reach the fleet"

# ── 2. the sudo grant stays narrow ───────────────────────────────────────────
grep -qE '^\$\{AGENT_USER\} ALL=\(root\) NOPASSWD: /usr/local/bin/sb-reboot$' "$STEP" \
  && ok "sudoers rule is scoped to exactly /usr/local/bin/sb-reboot" \
  || bad "sudoers rule is not the expected single narrow grant"

grep -qE 'NOPASSWD:[[:space:]]*ALL|ALL=\(ALL(:ALL)?\)' "$STEP" \
  && bad "19g grants blanket sudo — the whole point is a narrow, wrapper-scoped grant" \
  || ok "19g grants no blanket sudo"

# A broken drop-in in /etc/sudoers.d breaks sudo for the entire box, including
# sb-self-update — i.e. it would break the very path used to repair the fleet.
grep -q 'visudo -cf /etc/sudoers.d/sb-reboot' "$STEP" \
  && ok "sudoers drop-in is visudo-validated" \
  || bad "sudoers drop-in is not validated with visudo"
grep -q 'rm -f /etc/sudoers.d/sb-reboot' "$STEP" \
  && ok "an invalid sudoers drop-in is removed rather than left in place" \
  || bad "no rollback for an invalid sudoers drop-in"

# Never write a grant pointing at a wrapper that failed to install.
grep -q 'if \[ -x /usr/local/bin/sb-reboot \]' "$STEP_CODE" \
  && ok "sudoers is written only when the wrapper installed" \
  || bad "sudoers may be written without the wrapper present"

# ── 3. the wrapper uses the mechanism that actually works ────────────────────
# `reboot(8)` / a power-key press goes through logind's handle-power-key path, which
# unity-greeter blocks with an inhibitor on this image. `systemctl reboot` enqueues
# reboot.target with systemd directly and ignores that inhibitor entirely.
# Anchored at a command position, not merely "the string appears somewhere": the
# wrapper echoes the same text back in its own `note "reboot enqueued (…)"` line, so an
# unanchored grep matches even when the actual invocation has been swapped for
# `systemctl poweroff`. The mechanism IS the fix (risk #3 above) — assert the call site.
grep -qE '^[[:space:]]*(if[[:space:]]+)?systemctl[[:space:]]+reboot[[:space:]]+--no-block' "$WRAPPER_CODE" \
  && ok "wrapper reboots via 'systemctl reboot --no-block'" \
  || bad "wrapper does not invoke 'systemctl reboot --no-block'"

grep -qE '^[[:space:]]*(exec[[:space:]]+)?(/usr/sbin/|/sbin/)?reboot([[:space:]]|$)' "$WRAPPER_CODE" \
  && bad "wrapper calls plain reboot(8) — the ACPI path the greeter swallows" \
  || ok "wrapper does not fall back to plain reboot(8)"

# Two --force to systemctl means reboot(2) with no unmount. One is the accepted
# escalation; two would risk the filesystem on every routine portal reboot.
grep -qE 'systemctl.*--force.*--force|systemctl.*-ff' "$WRAPPER_CODE" \
  && bad "wrapper uses a double --force (immediate reboot(2), no unmount)" \
  || ok "wrapper never escalates to an unsynced hard reboot"

# ── 4. the wrapper reports a real result ─────────────────────────────────────
# This is what lets the daemon answer truthfully instead of hard-coding ok:true.
grep -qE '^[[:space:]]*exit 1[[:space:]]*$' "$WRAPPER_CODE" \
  && ok "wrapper exits non-zero when the reboot was refused" \
  || bad "wrapper has no failure exit — the daemon could not report a real failure"
grep -q 'SUDO_USER' "$WRAPPER_CODE" \
  && ok "wrapper records who asked (auditable privileged action)" \
  || bad "wrapper does not log the requester"

# ── 5. logind power-key policy ───────────────────────────────────────────────
grep -qE '^PowerKeyIgnoreInhibited=yes[[:space:]]*$' "$STEP_CODE" \
  && ok "logind drop-in sets PowerKeyIgnoreInhibited=yes (greeter can no longer swallow ACPI)" \
  || bad "logind drop-in does not set PowerKeyIgnoreInhibited"
grep -qE '^[[:space:]]*cat >[[:space:]]*/etc/systemd/logind\.conf\.d/50-agent-power\.conf' "$STEP_CODE" \
  && ok "logind policy lands in a drop-in, not by editing logind.conf" \
  || bad "logind policy is not written as a conf.d drop-in"
# Restarting logind on a live box with active RDP/X sessions is a real risk, and the
# path we depend on (sb-reboot) does not need the drop-in to be live.
grep -qE 'systemctl (restart|reload) systemd-logind' "$STEP_CODE" \
  && bad "19g restarts systemd-logind on a live box — the drop-in must wait for next boot" \
  || ok "19g does not restart systemd-logind (drop-in applies at next boot)"

echo
[ "$fail" = 0 ] && echo "PASS - test-19g-agent-reboot" || echo "FAIL - test-19g-agent-reboot"
exit "$fail"
