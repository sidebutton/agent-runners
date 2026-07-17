#!/usr/bin/env bash
# base/tests/test-19e-session-tidy.sh — regression guard for session-tidy (SCRUM-1769).
#
# Since PR #75 retired the 19e reaper ("Stop hook is the sole completion signal") nothing
# closed finished Claude TUIs, so they accumulated 12-23 per box per day until the box
# OOM-livelocked (2026-07-17 darwin: 23 claude procs = 7.7GB, manual hard reset). Session-tidy
# restores teardown WITHOUT re-coupling it to completion: base/14's stop hook MARKS a finished
# session (~/.sidebutton/session-stopped/<sid>.json = {pid, pid_start, stopped_at}), a
# UserPromptSubmit hook UN-marks it on re-engagement, and base/19e's sb-session-tidy timer
# CLOSES anything still marked after SB_SESSION_CLOSE_TTL_SEC.
#
# What this proves, in rough order of how much it would hurt to get wrong:
#   1. RISK #1 — the stop hook still POSTs step-complete even when the sentinel write FAILS.
#      The writer runs ahead of the only completion signal there is under `set -euo pipefail`,
#      so a non-zero there would strand EVERY job as 'running' fleet-wide: strictly worse than
#      the leak being fixed. This is the most valuable assertion in the file.
#   2. The sweep never signals a process it has not positively identified (comm + starttime),
#      and never touches the active job's session.
#   3. Mark on Stop only (SubagentStop fires mid-run), before the job-session gate.
#   4. The retired names are not re-used — base/14's decommission block deletes the old
#      sb-session-reaper units / session-done dir on EVERY refresh, so a name collision would
#      have the teardown delete its own replacement.
#
# The process fixtures are REAL: a copy of a real binary named `claude` (a bash script named
# `claude` gets comm=bash, and `bash -c '…' claude` only sets argv[0] — neither would exercise
# the comm check), so TERM/KILL and the /proc identity checks are exercised for real rather
# than against a stubbed `kill`.
#
# Pure bash + jq (both present on the runner). Run: bash base/tests/test-19e-session-tidy.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/19e-session-tidy.sh"
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
RUN="$BASE/run.sh"
MANIFEST="$BASE/refresh-manifest.txt"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

TMP="$(mktemp -d)"
cleanup() { pkill -P $$ -x claude 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ── 0. installer + generated payloads stay syntactically valid ────────────────
[ -f "$STEP" ] && bash -n "$STEP" 2>/dev/null && ok "bash -n: 19e-session-tidy.sh" || bad "19e missing / syntax error"
bash -n "$HOOK" 2>/dev/null && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on 14"

awk "/cat > \"\\\$TIDY_DEST\" <<'EOF'/{f=1;next} /^EOF\$/{f=0} f" "$STEP" > "$TMP/sb-session-tidy.sh"
awk "/cat > .*claude-stop-hook.sh.*<<'HOOKEOF'/{f=1;next} /^HOOKEOF\$/{f=0} f" "$HOOK" > "$TMP/claude-stop-hook.sh"
awk "/cat > .*sb-clear-session-stopped.sh.*<<'CLEAREOF'/{f=1;next} /^CLEAREOF\$/{f=0} f" "$HOOK" > "$TMP/sb-clear-session-stopped.sh"
chmod +x "$TMP"/*.sh
[ -s "$TMP/sb-session-tidy.sh" ] && bash -n "$TMP/sb-session-tidy.sh" && ok "bash -n: generated sb-session-tidy.sh" || bad "generated sweep missing / syntax error"
[ -s "$TMP/claude-stop-hook.sh" ] && bash -n "$TMP/claude-stop-hook.sh" && ok "bash -n: generated claude-stop-hook.sh" || bad "generated stop hook missing / syntax error"
[ -s "$TMP/sb-clear-session-stopped.sh" ] && bash -n "$TMP/sb-clear-session-stopped.sh" && ok "bash -n: generated sb-clear-session-stopped.sh" || bad "generated clear hook missing / syntax error"

# ── 1. the mark is written on Stop only, and BEFORE the job-session gate ──────
# SubagentStop fires when a sub-agent returns while the main agent is still working; marking
# there would arm the sweep against a live session.
grep -q 'if \[ "\$HOOK_EVENT" = "Stop" \]; then' "$TMP/claude-stop-hook.sh" \
  && grep -q 'mark_session_stopped "\$SESSION_ID" || true' "$TMP/claude-stop-hook.sh" \
  && ok "sentinel writer is gated to hook_event_name=Stop" \
  || bad "sentinel writer is not Stop-gated (SubagentStop would mark a live session)"
# The gate exits 0 for a lingering/operator session — precisely the sessions that accumulate —
# so the mark must land BEFORE it or those are never closed.
awk '/mark_session_stopped "\$SESSION_ID"/{m=NR} /!= job session \$JOB_SID/{g=NR} END{exit !(m && g && m<g)}' \
  "$TMP/claude-stop-hook.sh" \
  && ok "the mark is written BEFORE the job-session gate (operator/lingering sessions marked too)" \
  || bad "the mark is gated behind the job-session check — lingering sessions would never be closed"
# `|| true` at the call site + guarded internals: the writer precedes the sole completion signal.
grep -q 'mark_session_stopped "\$SESSION_ID" || true' "$TMP/claude-stop-hook.sh" \
  && ok "writer call site is || true (cannot abort the completion POSTs under set -e)" \
  || bad "writer call site lacks || true — a failure would strand every job as 'running'"
# PPid must come from /proc/<p>/status, not `awk` on /proc/<p>/stat: a comm containing spaces
# shifts stat's fields and the walk would climb to the wrong pid.
grep -q "PPid:" "$TMP/claude-stop-hook.sh" \
  && ok "ancestor walk reads PPid from /proc/<p>/status (space-in-comm safe)" \
  || bad "ancestor walk does not use /proc/<p>/status PPid"

# ── 2. the retired names are NOT re-used ─────────────────────────────────────
# base/14's decommission block deletes sb-session-reaper.{timer,service}, /opt/sb-session-reaper.sh
# and session-done/ on EVERY refresh (it stays for older fleets), so re-using a retired name would
# have the teardown delete the replacement it precedes.
retired_clean=1
for n in 'sb-session-reaper' 'session-done' 'SB_SESSION_MAX_IDLE_SEC'; do
  grep -q "$n" "$TMP/sb-session-tidy.sh" && { bad "sweep re-uses the retired name: $n"; retired_clean=0; }
  grep -q "$n" "$TMP/sb-clear-session-stopped.sh" && { bad "clear hook re-uses the retired name: $n"; retired_clean=0; }
done
[ "$retired_clean" = 1 ] && ok "no retired reaper names re-used (decommission block cannot eat the replacement)"
# The decommission block's UserPromptSubmit strip keys off the retired command string. If it ever
# matched the new entry, every refresh would strip the hook right after installing it.
if command -v jq >/dev/null 2>&1; then
  if jq -e '(.hooks.UserPromptSubmit // []) | tostring | contains("sb-clear-session-done")' "$HOOKS_JSON" >/dev/null 2>&1; then
    bad "base/14's strip matches the new UserPromptSubmit entry — refresh would delete it"
  else
    ok "base/14's decommission strip does not match the new UserPromptSubmit entry"
  fi
fi

# ── 3. hooks asset wiring ────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  jq -e . "$HOOKS_JSON" >/dev/null 2>&1 && ok "claude-hooks.json is valid JSON" || bad "claude-hooks.json is not valid JSON"
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null)" = '$HOME/.local/bin/sb-clear-session-stopped.sh' ] \
    && ok "claude-hooks.json wires UserPromptSubmit -> sb-clear-session-stopped.sh" \
    || bad "claude-hooks.json does not wire UserPromptSubmit -> sb-clear-session-stopped.sh"
  # The _comment is the single source of truth operators read; PR #75 left it asserting
  # "no session reaper", which this change makes false.
  jq -r '._comment' "$HOOKS_JSON" 2>/dev/null | grep -q 'no session reaper' \
    && bad "_comment still asserts 'no session reaper' (now false)" \
    || ok "_comment no longer asserts 'no session reaper'"
  jq -r '._comment' "$HOOKS_JSON" 2>/dev/null | grep -q 'ONLY by the Stop hook' \
    && ok "_comment still records step-complete as the SOLE completion signal" \
    || bad "_comment lost the 'completion is signalled ONLY by step-complete' invariant"
fi
grep -q 'sb-clear-session-stopped.sh' "$HOOK" && ok "base/14 installs sb-clear-session-stopped.sh" || bad "base/14 does not install sb-clear-session-stopped.sh"

# ── 4. run.sh + manifest wiring (fleet reach) ────────────────────────────────
grep -qF '19e-session-tidy.sh' "$RUN" && ok "run.sh sources 19e" || bad "run.sh does NOT source 19e"
awk '/19d-account-registry.sh/{d=NR} /19e-session-tidy.sh/{e=NR} /19f-component-config.sh/{f=NR} /20-mark-installed.sh/{m=NR} END{exit !(d<e && e<f && f<m)}' "$RUN" \
  && ok "run.sh orders 19e after 19d, before 19f and 20-mark-installed" || bad "19e mis-ordered in run.sh"
grep -qxF '19e-session-tidy.sh' <(sed -e 's/[[:space:]]*#.*$//' "$MANIFEST") \
  && ok "refresh-manifest.txt lists 19e (fleet reach without re-provisioning)" || bad "refresh-manifest.txt missing 19e"
# Manifest order is fingerprint order — keep it numeric so a re-order is not a phantom change.
awk '!/^[[:space:]]*#/ && NF {print}' "$MANIFEST" | awk '/19d-account-registry.sh/{d=NR} /19e-session-tidy.sh/{e=NR} /19f-component-config.sh/{f=NR} END{exit !(d<e && e<f)}' \
  && ok "manifest keeps numeric (= fingerprint) order around 19e" || bad "manifest order around 19e is not numeric"
# The refresh path re-runs manifest steps WITHOUT AGENT_COMPONENTS / has_component, so a
# component gate here would evaluate differently at provision vs refresh and silently skip the fleet.
if grep -v '^[[:space:]]*#' "$STEP" | grep -Eq 'has_component|AGENT_COMPONENTS|INSTALL_CLAUDE_CODE'; then
  bad "19e gates on a component signal — unavailable on the refresh path, would skip the fleet"
else
  ok "19e uses no component gate (refresh-safe; the sweep self-noops instead)"
fi

# ── 5. functional sweep ──────────────────────────────────────────────────────
# A copy of a real binary named `claude` => comm=claude, and it really dies on TERM.
CLAUDE_BIN="$TMP/bin/claude"
mkdir -p "$TMP/bin"
cp "$(command -v sleep)" "$CLAUDE_BIN" 2>/dev/null || true
FAKE_HOME="$TMP/home"
STOPPED="$FAKE_HOME/.sidebutton/session-stopped"
mkdir -p "$STOPPED"

starttime_of() {  # field 22, indexed after the LAST ") " so a spacey comm cannot shift it
  local line rest; line="$(cat "/proc/$1/stat" 2>/dev/null || true)"; [ -n "$line" ] || return 1
  rest="${line##*) }"; printf '%s' "$rest" | awk '{print $20}'
}
# >/dev/null on the fixture is load-bearing: it is captured via $(…), and a background
# child inheriting the substitution's stdout pipe holds it open until the child exits.
spawn_claude() { "$CLAUDE_BIN" 300 >/dev/null 2>&1 & echo $!; }
mark() {  # <sid> <pid> <stopped_at> [pid_start]
  local st="${4:-$(starttime_of "$2")}"
  jq -nc --argjson pid "$2" --argjson pid_start "$st" --argjson stopped_at "$3" \
    '{pid:$pid, pid_start:$pid_start, stopped_at:$stopped_at}' > "$STOPPED/$1.json"
}
sweep() { env -i HOME="$FAKE_HOME" PATH="$PATH" \
  SB_SESSION_CLOSE_TTL_SEC="${1:-3600}" SB_SESSION_TERM_GRACE_SEC=1 \
  bash "$TMP/sb-session-tidy.sh" >/dev/null 2>&1; }
alive() { kill -0 "$1" 2>/dev/null; }

if [ ! -x "$CLAUDE_BIN" ] || [ "$(cat /proc/$$/comm 2>/dev/null)" = "" ]; then
  skip "no /proc or no spawnable fixture — skipping the functional sweep"
else
  NOW="$(date +%s)"

  # 5a. past TTL => TERM'd and the sentinel pruned
  P_OLD="$(spawn_claude)"; sleep 0.2
  [ "$(cat /proc/$P_OLD/comm 2>/dev/null)" = "claude" ] || bad "fixture setup: comm is not 'claude' (test would be vacuous)"
  mark old "$P_OLD" "$(( NOW - 7200 ))"
  # 5b. fresh (inside TTL) => spared
  P_NEW="$(spawn_claude)"; sleep 0.2
  mark fresh "$P_NEW" "$(( NOW - 60 ))"
  # 5c. the active job's session => spared however old the mark is
  P_JOB="$(spawn_claude)"; sleep 0.2
  mark jobsid "$P_JOB" "$(( NOW - 7200 ))"
  echo '{"session_id":"jobsid","job_id":1,"step_index":0}' > "$FAKE_HOME/.sidebutton/job-context.json"
  # 5d. starttime mismatch (pid recycled / `claude --continue` resumed the sid in a NEW process)
  #     => prune the sentinel, never signal the live process
  P_REUSE="$(spawn_claude)"; sleep 0.2
  mark reused "$P_REUSE" "$(( NOW - 7200 ))" "$(( $(starttime_of "$P_REUSE") + 12345 ))"
  # 5e. corrupt sentinel => pruned, no crash
  printf 'not json at all' > "$STOPPED/corrupt.json"

  sweep 3600
  sleep 0.3

  alive "$P_OLD"   && bad "past-TTL session survived the sweep"        || ok "past-TTL session is closed (real SIGTERM)"
  [ -f "$STOPPED/old.json" ] && bad "closed session's sentinel not pruned" || ok "closed session's sentinel is pruned"
  alive "$P_NEW"   && ok "inside-TTL session is spared"                || bad "inside-TTL session was killed"
  [ -f "$STOPPED/fresh.json" ] && ok "inside-TTL sentinel is kept"     || bad "inside-TTL sentinel was pruned"
  alive "$P_JOB"   && ok "active job-context session is spared (however old the mark)" || bad "ACTIVE JOB SESSION WAS KILLED"
  alive "$P_REUSE" && ok "starttime mismatch: live process is NOT signalled" || bad "starttime mismatch: killed the wrong process"
  [ -f "$STOPPED/reused.json" ] && bad "stale (mismatched) sentinel not pruned" || ok "starttime mismatch: sentinel pruned instead"
  [ -f "$STOPPED/corrupt.json" ] && bad "corrupt sentinel not pruned (would be re-read forever)" || ok "corrupt sentinel is pruned"
  grep -q 'tick: seen=' "$FAKE_HOME/.sidebutton/session-tidy.log" 2>/dev/null \
    && ok "sweep logs a per-tick summary (a 'never closes' regression stays visible)" \
    || bad "sweep wrote no per-tick summary line"

  # 5f. TTL=0 is the documented per-box kill switch
  P_KS="$(spawn_claude)"; sleep 0.2
  mark killswitch "$P_KS" "$(( NOW - 7200 ))"
  sweep 0; sleep 0.2
  alive "$P_KS" && ok "SB_SESSION_CLOSE_TTL_SEC=0 disables the sweep (kill switch)" || bad "TTL=0 still killed a session"
  # 5g. a malformed TTL must disable, never fall back to a default that starts killing
  sweep "not-a-number"; sleep 0.2
  alive "$P_KS" && ok "malformed TTL disables the sweep (no killing fallback)" || bad "malformed TTL killed a session"
  kill "$P_NEW" "$P_JOB" "$P_REUSE" "$P_KS" 2>/dev/null || true
fi

# ── 6. functional writer: Stop marks, SubagentStop does not, and RISK #1 ─────
# The hook's ancestor walk looks for comm=claude, so the fixture parent is a copy of bash
# named `claude` — mirroring the real claude -> shell -> hook tree.
CLAUDE_SH="$TMP/bin/claude-sh/claude"
mkdir -p "$TMP/bin/claude-sh"
cp "$(command -v bash)" "$CLAUDE_SH" 2>/dev/null || true
W_HOME="$TMP/whome"; mkdir -p "$W_HOME/.sidebutton"
# Stub curl on PATH: the POSTs must be observable without a portal.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 0
CURLEOF
chmod +x "$TMP/stub/curl"

# The `claude` parent records its OWN pid + stat before running the hook, so the walk's
# result is checked against ground truth rather than by re-reading /proc after it exits
# (it is gone by then — that race would silently skip the assertion).
run_hook() {  # <event> <session_id>; echoes nothing, writes into $W_HOME
  local ev="$1" sid="$2"
  printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"","duration_ms":1,"total_cost_usd":0}' "$sid" "$ev" \
  | env -i HOME="$W_HOME" PATH="$TMP/stub:$PATH" CURL_LOG="$TMP/curl.log" \
      AGENT_TOKEN=t AGENT_NAME=a PORTAL_URL=http://127.0.0.1:1 \
      "$CLAUDE_SH" -c 'echo $$ > "$1"; cat /proc/$$/stat > "$2"; exec 3<&0; bash "$0" <&3; :' \
      "$TMP/claude-stop-hook.sh" "$TMP/parent.pid" "$TMP/parent.stat" >/dev/null 2>&1
}

if [ ! -x "$CLAUDE_SH" ] || ! command -v jq >/dev/null 2>&1; then
  skip "no bash copy / jq — skipping the functional writer assertions"
else
  : > "$TMP/curl.log"
  run_hook Stop sess-aaa
  S="$W_HOME/.sidebutton/session-stopped/sess-aaa.json"
  if [ -f "$S" ]; then
    ok "Stop writes the session-stopped sentinel"
    [ "$(jq -r 'has("pid") and has("pid_start") and has("stopped_at")' "$S" 2>/dev/null)" = "true" ] \
      && ok "sentinel carries pid + pid_start + stopped_at" || bad "sentinel is missing a required field: $(cat "$S")"
    # Ground truth recorded by the comm=claude parent itself (see run_hook).
    EXP_PID="$(cat "$TMP/parent.pid" 2>/dev/null || echo x)"
    EXP_START="$(rest="$(cat "$TMP/parent.stat" 2>/dev/null)"; printf '%s' "${rest##*) }" | awk '{print $20}')"
    [ "$(jq -r '.pid' "$S")" = "$EXP_PID" ] \
      && ok "sentinel pid IS the nearest comm=claude ancestor (walk resolves correctly)" \
      || bad "sentinel pid $(jq -r '.pid' "$S") != the claude ancestor $EXP_PID"
    [ -n "$EXP_START" ] && [ "$(jq -r '.pid_start' "$S")" = "$EXP_START" ] \
      && ok "sentinel pid_start matches that process's real /proc starttime (PID-reuse guard)" \
      || bad "sentinel pid_start $(jq -r '.pid_start' "$S") != real starttime $EXP_START"
  else
    bad "Stop did not write a sentinel"
  fi

  # A later Stop overwrites, so the clock runs from the LAST completion.
  OLD_TS="$(jq -r '.stopped_at' "$S" 2>/dev/null || echo 0)"
  jq -c '.stopped_at = 1' "$S" > "$S.x" 2>/dev/null && mv "$S.x" "$S"
  run_hook Stop sess-aaa
  [ "$(jq -r '.stopped_at' "$S" 2>/dev/null || echo 1)" != "1" ] \
    && ok "a later Stop overwrites the mark (clock runs from the LAST completion)" \
    || bad "a later Stop did not refresh stopped_at"

  run_hook SubagentStop sess-bbb
  [ -f "$W_HOME/.sidebutton/session-stopped/sess-bbb.json" ] \
    && bad "SubagentStop wrote a sentinel (fires mid-run — would close a live session)" \
    || ok "SubagentStop does NOT write a sentinel"

  # Path traversal: session_id is stdin JSON used as a filename.
  run_hook Stop '../../evil'
  [ -f "$TMP/evil.json" ] || [ -f "$W_HOME/evil.json" ] \
    && bad "traversal session_id escaped the sentinel dir" \
    || ok "traversal session_id is rejected (charset-validated)"

  # ── RISK #1 — the one that must never regress ──────────────────────────────
  # With the sentinel dir unwritable, step-complete must still be POSTed. `session-stopped`
  # is planted as a regular FILE so mkdir -p fails for root too (chmod would not stop root).
  W2="$TMP/whome2"; mkdir -p "$W2/.sidebutton"
  printf 'block' > "$W2/.sidebutton/session-stopped"
  : > "$TMP/curl2.log"
  printf '{"session_id":"sess-ccc","hook_event_name":"Stop","transcript_path":"","duration_ms":1,"total_cost_usd":0}' \
  | env -i HOME="$W2" PATH="$TMP/stub:$PATH" CURL_LOG="$TMP/curl2.log" \
      AGENT_TOKEN=t AGENT_NAME=a PORTAL_URL=http://127.0.0.1:1 \
      "$CLAUDE_SH" -c 'exec 3<&0; bash "$0" <&3; :' "$TMP/claude-stop-hook.sh" >/dev/null 2>&1
  if grep -q '/api/jobs/step-complete' "$TMP/curl2.log" 2>/dev/null; then
    ok "RISK #1: sentinel write FAILS -> step-complete is still POSTed (job cannot strand)"
  else
    bad "RISK #1 REGRESSION: a failed sentinel write suppressed step-complete — every job would strand as 'running'"
  fi
  grep -q '/api/jobs/usage' "$TMP/curl2.log" 2>/dev/null \
    && ok "RISK #1: usage POST also survives a failed sentinel write" \
    || bad "RISK #1: a failed sentinel write suppressed the usage POST"
fi

# ── 7. functional clear hook ─────────────────────────────────────────────────
C_HOME="$TMP/chome"; mkdir -p "$C_HOME/.sidebutton/session-stopped"
: > "$C_HOME/.sidebutton/session-stopped/mine.json"
: > "$C_HOME/.sidebutton/session-stopped/other.json"
if command -v jq >/dev/null 2>&1; then
  printf '{"session_id":"mine"}' | env -i HOME="$C_HOME" PATH="$PATH" bash "$TMP/sb-clear-session-stopped.sh" >/dev/null 2>&1
  [ -f "$C_HOME/.sidebutton/session-stopped/mine.json" ] \
    && bad "clear hook did not remove its own sentinel" || ok "clear hook removes its own sentinel (re-engaged session is never closed)"
  [ -f "$C_HOME/.sidebutton/session-stopped/other.json" ] \
    && ok "clear hook leaves other sessions' sentinels alone" || bad "clear hook removed another session's sentinel"

  : > "$C_HOME/.sidebutton/session-stopped/other.json"
  printf '{}' | env -i HOME="$C_HOME" PATH="$PATH" bash "$TMP/sb-clear-session-stopped.sh" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 0 ] && ok "clear hook exits 0 on empty session_id (never disturbs a prompt)" || bad "clear hook exit=$rc on empty session_id"
  [ -f "$C_HOME/.sidebutton/session-stopped/other.json" ] \
    && ok "empty session_id is a no-op (no blanket delete)" || bad "empty session_id deleted a sentinel"

  printf '{"session_id":"../../../etc/passwd"}' | env -i HOME="$C_HOME" PATH="$PATH" bash "$TMP/sb-clear-session-stopped.sh" >/dev/null 2>&1
  [ "$?" = 0 ] && ok "clear hook rejects a traversal session_id and exits 0" || bad "clear hook mishandled a traversal session_id"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
