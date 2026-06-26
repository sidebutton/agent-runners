#!/usr/bin/env bash
# base/tests/test-19e-session-reaper.sh — regression guard for the SCRUM-1433
# sentinel idle signal in 19e-session-reaper.sh (+ its two halves in
# 14-claude-stop-hook.sh and assets/claude-hooks.json).
#
# THE BUG: the reaper measured idleness as `now - mtime(transcript)`. Transcript
# mtime tracks process LIVENESS, not task completion — an idle Claude TUI rewrites
# its own transcript (Ink render + autosave) and operator steers (SCRUM-1384) append
# to it — so mtime never went stale and the reaper logged seen=N reaped=0 forever
# while finished ghost sessions piled up (SCRUM-1250 → SCRUM-1354 → SCRUM-1433).
#
# THE FIX: idle is read from a per-session "session-done" SENTINEL written ONCE by
# the stop hook at the genuine session end (~/.sidebutton/session-done/<sid>), which
# no later transcript write can touch. A UserPromptSubmit hook removes the sentinel
# on re-engagement so an actively-working session is never reaped. The reaper:
#   sentinel ABSENT  => still running => skip
#   sentinel PRESENT => idle = now - mtime(sentinel); reap at GRACE; rm after reap
#   + sweep sentinels whose session has no live process (orphans).
#
# This proves: (0) both scripts stay syntactically valid; (1) the fix is present and
# the old transcript-mtime signal is gone; (2) end-to-end, the extracted /opt reaper
# reaps a past-grace session, spares a fresh one and a sentinel-less one (AC3), cleans
# the sentinel after reaping (AC4), and sweeps orphans; (3) the clear hook removes
# only its own sentinel. NO real `claude` process is touched — pgrep/kill are stubbed.
#
# Pure bash; the clear-hook assertions also need jq (present on CI; skipped if absent).
# Run: bash base/tests/test-19e-session-reaper.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
REAPER="$BASE/19e-session-reaper.sh"
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 0. installers stay valid ────────────────────────────────────────────────────
bash -n "$REAPER" && ok "bash -n: 19e-session-reaper.sh" || bad "bash -n failed on the reaper"
bash -n "$HOOK"   && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the stop hook"

# ── 1. the fix is present; the old transcript-mtime signal is gone ───────────────
grep -q 'SESSION_DONE_DIR=' "$REAPER" \
  && ok "reaper defines the session-done sentinel dir" \
  || bad "reaper missing SESSION_DONE_DIR"
grep -q 'stat -c %Y "\$sentinel"' "$REAPER" \
  && ok "reaper measures idle from the sentinel mtime" \
  || bad "reaper does not read the sentinel mtime"
! grep -q 'stat -c %Y "\$transcript"' "$REAPER" \
  && ok "reaper no longer reads the transcript mtime (the defeated signal)" \
  || bad "reaper still reads transcript mtime"
! grep -q 'PROJECTS_DIR' "$REAPER" \
  && ok "reaper dropped the now-unused PROJECTS_DIR transcript lookup" \
  || bad "reaper still references PROJECTS_DIR"
grep -q 'swept orphan sentinel' "$REAPER" \
  && ok "reaper sweeps orphan sentinels (AC4)" \
  || bad "reaper has no orphan sweep"
grep -q 'session-done sentinel written for \$SESSION_ID' "$HOOK" \
  && ok "stop hook writes the sentinel on the final Stop" \
  || bad "stop hook does not write the sentinel"
grep -q 'sb-clear-session-done.sh' "$HOOK" \
  && ok "stop hook installs the UserPromptSubmit clear hook" \
  || bad "clear hook not installed by base/14"
grep -q '"UserPromptSubmit"' "$HOOKS_JSON" && grep -q 'sb-clear-session-done.sh' "$HOOKS_JSON" \
  && ok "claude-hooks.json wires UserPromptSubmit -> sb-clear-session-done.sh" \
  || bad "claude-hooks.json missing the UserPromptSubmit clear hook"

# ── 2. functional: drive the extracted /opt reaper against fake sessions ─────────
# Extract the runtime the installer writes to /opt, and run it against a temp HOME.
awk '/^cat > "\$REAPER_DEST" <<.EOF.$/{f=1;next} /^EOF$/{if(f){f=0;exit}} f{print}' \
  "$REAPER" > "$TMP/reaper.sh"
bash -n "$TMP/reaper.sh" && ok "bash -n: extracted /opt reaper runtime" || bad "extracted reaper has a syntax error"

THOME="$TMP/home"; SDONE="$THOME/.sidebutton/session-done"; mkdir -p "$SDONE"
KLOG="$TMP/kill.log"; : > "$KLOG"

# Long-lived fakes whose /proc/PID/cmdline carries `--session-id <uuid>` exactly as a
# real `claude --session-id …` does. `; :` keeps the -c body compound so bash does not
# exec-optimise into `sleep` (which would strip the trailing args from the cmdline).
bash -c 'sleep 60; :' claude 60 --session-id reapme-uuid     & PID_REAP=$!
bash -c 'sleep 60; :' claude 60 --session-id keepme-uuid     & PID_KEEP=$!
bash -c 'sleep 60; :' claude 60 --session-id nosentinel-uuid & PID_NONE=$!
( sleep 0.4 ) 2>/dev/null || true   # let the children settle so /proc/PID/cmdline is populated

# Sentinels: reapme = 2h old (>GRACE) -> reap; keepme = now (<GRACE) -> keep;
# nosentinel = none -> still running; orphan = no live process -> swept.
: > "$SDONE/reapme-uuid"; touch -d '2 hours ago' "$SDONE/reapme-uuid"
: > "$SDONE/keepme-uuid"
: > "$SDONE/orphan-uuid"

pgrep(){ echo "$PID_REAP"; echo "$PID_KEEP"; echo "$PID_NONE"; }   # only our fakes
kill(){ echo "kill $*" >> "$KLOG"; return 0; }                     # never signal a real pid
export -f pgrep kill
export PID_REAP PID_KEEP PID_NONE KLOG

HOME="$THOME" SB_SESSION_MAX_IDLE_SEC=3600 SB_SESSION_TERM_GRACE_SEC=0 \
  bash "$TMP/reaper.sh"
unset -f pgrep kill

RLOG="$THOME/.sidebutton/session-reaper.log"
[ ! -e "$SDONE/reapme-uuid" ]                     && ok "AC1/AC4: past-grace session reaped, sentinel removed" || bad "reapme sentinel not cleaned after reap"
grep -q "kill -TERM $PID_REAP" "$KLOG"            && ok "AC1: past-grace session got SIGTERM"                  || bad "reapme not SIGTERMed"
grep -q "reaping pid=$PID_REAP sid=reapme-uuid" "$RLOG" && ok "AC1: reap logged for reapme"                    || bad "no reap log for reapme"
[ -e "$SDONE/keepme-uuid" ]                       && ok "AC3: fresh-sentinel session spared"                   || bad "keepme wrongly cleaned"
! grep -q "kill -TERM $PID_KEEP" "$KLOG"          && ok "AC3: fresh-sentinel session not killed"               || bad "keepme wrongly killed"
! grep -q "kill -TERM $PID_NONE" "$KLOG"          && ok "AC3: sentinel-less (still-running) session not killed" || bad "nosentinel wrongly killed"
[ ! -e "$SDONE/orphan-uuid" ]                     && ok "AC4: orphan sentinel swept"                            || bad "orphan sentinel not swept"
grep -q "reaped=1 " "$RLOG"                        && ok "tick summary reports reaped=1"                         || { echo "--- reaper log ---"; cat "$RLOG"; bad "tick summary not reaped=1"; }

command kill -TERM "$PID_REAP" "$PID_KEEP" "$PID_NONE" 2>/dev/null || true

# ── 3. functional: the clear hook removes only its own sentinel ──────────────────
if command -v jq >/dev/null 2>&1; then
  awk '/<<.CLEAREOF.$/{f=1;next} /^CLEAREOF$/{f=0} f{print}' "$HOOK" > "$TMP/clear.sh"
  bash -n "$TMP/clear.sh" && ok "bash -n: extracted sb-clear-session-done.sh" || bad "clear hook has a syntax error"
  CH="$TMP/chome"; mkdir -p "$CH/.sidebutton/session-done"
  : > "$CH/.sidebutton/session-done/mine"; : > "$CH/.sidebutton/session-done/other"
  echo '{"session_id":"mine","hook_event_name":"UserPromptSubmit"}' | HOME="$CH" bash "$TMP/clear.sh"
  [ ! -e "$CH/.sidebutton/session-done/mine" ]  && ok "AC3: clear hook removed its own sentinel"   || bad "clear hook did not remove 'mine'"
  [ -e "$CH/.sidebutton/session-done/other" ]   && ok "AC3: clear hook left other sessions alone"  || bad "clear hook removed 'other'"
  echo '{}' | HOME="$CH" bash "$TMP/clear.sh"    && ok "clear hook is a no-op on empty session_id" || bad "clear hook errored on empty session_id"
else
  skip "clear-hook functional test (jq not installed)"
fi

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
