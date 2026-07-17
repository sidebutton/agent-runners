# 19e-session-tidy.sh — close finished Claude Code sessions (SCRUM-1769).
#
# A dispatched job launches Claude Code as an interactive TUI in a desktop terminal
# so an operator can watch the run on the live-desktop preview. When the run
# FINISHES the TUI does not exit — it sits at the prompt holding its full heap.
# PR #75 retired the previous reaper ("Stop hook is the sole completion signal")
# and accepted the trade-off that "session teardown is a dispatch-side concern
# now", but that dispatch-side teardown was never built, so NOTHING closes finished
# sessions. They accumulate 12–23 per box per day (4.5–7.7GB), fill RAM + the 4GB
# swap (base/09), and the next heavy job tips the box into a memory livelock the
# platform cannot see or fix: at the 2026-07-17 darwin OOM the task dump held 23
# `claude` processes = 7.7GB, and the box needed a manual Hetzner hard reset.
#
# This step installs the sweep half of session-tidy. The mark half lives in base/14:
# on `hook_event_name = Stop` the stop hook writes
# ~/.sidebutton/session-stopped/<session_id>.json = {pid, pid_start, stopped_at},
# and a UserPromptSubmit hook (sb-clear-session-stopped.sh) REMOVES it the moment
# the session is re-engaged. So:
#   sentinel ABSENT  => never finished, or working again => leave alone
#   sentinel PRESENT => finished at stopped_at; close once age >= TTL
#
# HARD-DECOUPLED FROM COMPLETION (the lesson of SCRUM-1250 -> 1354 -> 1433 -> #75):
# this sweep makes no portal POSTs, reads no job state, and never infers completion.
# The stop hook's step-complete POST remains the sole completion signal, untouched.
# The sentinel is a purely LOCAL lifecycle marker. Nor does it re-use the idle
# heuristics that defeated every predecessor: CPU flatness (a finished TUI holds ~1%
# CPU forever) and transcript mtime (an idle TUI's own Ink renders + operator steers
# keep it fresh) both measured LIVENESS, not completion. stopped_at is written once,
# at the genuine end of a run, and no later activity can refresh it.
#
# TTL defaults to 60 min — deliberately ABOVE the portal's idleRecovery ceiling
# (max 30 min) so a genuinely stuck job is always released by the portal BEFORE its
# session is closed, and the two can never fight over the same run.
#
# NEW NAMES ARE LOAD-BEARING: base/14 carries a decommission block that deletes
# sb-session-reaper.{timer,service}, /opt/sb-session-reaper.sh and session-done/ on
# EVERY refresh (it must stay for older fleets). Naming this sb-session-tidy /
# session-stopped/ is what keeps that teardown from deleting this replacement.
#
# NOT gated on a component. The refresh path (base/lib-refresh.sh) re-runs manifest
# steps WITHOUT AGENT_COMPONENTS / has_component / INSTALL_CLAUDE_CODE — it only
# synthesizes SKIP_SIDEBUTTON_SERVER + SKIP_KNOWLEDGE_PACKS from the SB server unit
# — so gating on the claude-code gate would evaluate differently at provision vs
# refresh and silently skip the fleet (the trap 19f's header documents). Instead the
# sweep self-noops: no session-stopped/ dir (no Claude, or nothing finished yet) =>
# exit 0. It needs only jq + systemd, no SB server, so SKIP_SIDEBUTTON_SERVER does
# not gate it either. Sourced-safe: never exits the installer — logs WARN, continues.

step "Step 19e/16: finished Claude Code session tidy (sb-session-tidy timer)"

TIDY_DEST="/opt/sb-session-tidy.sh"

cat > "$TIDY_DEST" <<'EOF'
#!/usr/bin/env bash
# /opt/sb-session-tidy.sh — close Claude Code sessions that finished a while ago.
# Installed by agent-runners base/19e (SCRUM-1769).
#
# Reads the per-session sentinels base/14's stop hook writes at the genuine end of a
# run (~/.sidebutton/session-stopped/<sid>.json = {pid, pid_start, stopped_at}) and
# closes any whose stopped_at is older than SB_SESSION_CLOSE_TTL_SEC. Stateless: each
# tick re-reads the dir. Makes NO portal calls and reads no job state — the stop
# hook's step-complete POST is the sole completion signal and this sweep is
# deliberately decoupled from it.
set -uo pipefail

TTL="${SB_SESSION_CLOSE_TTL_SEC:-3600}"           # close this long after the LAST Stop; 0 disables
TERM_GRACE="${SB_SESSION_TERM_GRACE_SEC:-10}"     # wait between SIGTERM and SIGKILL
STATE_DIR="${HOME:-/home/agent}/.sidebutton"
LOG_FILE="${STATE_DIR}/session-tidy.log"
JOB_CONTEXT="${STATE_DIR}/job-context.json"
STOPPED_DIR="${STATE_DIR}/session-stopped"

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# TTL=0 is the documented per-box kill switch (set it in ~/.agent-env). A malformed
# value disables too — never fall back to a default that starts killing processes.
case "$TTL" in
  0) exit 0 ;;
  ''|*[!0-9]*) log "invalid SB_SESSION_CLOSE_TTL_SEC='${TTL}' — sweep disabled this tick"; exit 0 ;;
esac
case "$TERM_GRACE" in ''|*[!0-9]*) TERM_GRACE=10 ;; esac

# Nothing has finished (or there is no Claude on this box) — no dir, no work.
[ -d "$STOPPED_DIR" ] || exit 0

now="$(date +%s)"

# The session of the CURRENT dispatch is never closed, no matter how old its last
# Stop is: a job whose session is mid-run (an early Stop then re-engaged, a resumed
# run) must survive. job-context is rewritten per dispatch, so this protects the most
# recent dispatch only — a previous job's session becomes eligible once the next job
# starts, which is intended and is what holds steady state at 1-2 sessions.
JOB_SID=""
[ -r "$JOB_CONTEXT" ] && JOB_SID="$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)"

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# starttime = /proc/<pid>/stat field 22. comm (field 2) is parenthesized and may hold
# spaces/parens, so cut through the LAST ") " and index from field 3: 22 - 2 = 20.
proc_starttime() {
  local line rest
  line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  rest="${line##*) }"
  printf '%s' "$rest" | awk '{print $20}' 2>/dev/null || return 1
}

# Is <pid> still the exact process the stop hook marked? comm must be claude AND the
# starttime must match — starttime is the PID-reuse guard. This is what makes
# `claude --continue` safe: it resumes the SAME session id in a NEW process, so the
# stale sentinel's pid either no longer exists or is somebody else, and we prune
# rather than kill the live resumed session.
is_marked_claude() {
  local p="$1" want="$2" comm cur
  comm="$(cat "/proc/$p/comm" 2>/dev/null || true)"
  [ "$comm" = "claude" ] || return 1
  cur="$(proc_starttime "$p" || true)"
  [ -n "$cur" ] && [ "$cur" = "$want" ]
}

kill_pids=(); kill_starts=(); kill_sids=()
seen=0; closed=0; skipped=0; pruned=0

for sfile in "$STOPPED_DIR"/*.json; do
  [ -e "$sfile" ] || continue          # empty dir: the glob stays literal
  base="${sfile##*/}"; sid="${base%.json}"
  seen=$(( seen + 1 ))

  if [ -n "$JOB_SID" ] && [ "$sid" = "$JOB_SID" ]; then
    skipped=$(( skipped + 1 )); continue
  fi

  pid="$(jq -r '.pid // empty' "$sfile" 2>/dev/null || true)"
  pid_start="$(jq -r '.pid_start // empty' "$sfile" 2>/dev/null || true)"
  stopped_at="$(jq -r '.stopped_at // empty' "$sfile" 2>/dev/null || true)"
  # Corrupt/truncated/foreign file: nothing safe to act on, and it would be re-read
  # every tick forever. Drop it — the next Stop rewrites a good one.
  if ! is_num "$pid" || ! is_num "$pid_start" || ! is_num "$stopped_at"; then
    rm -f "$sfile" 2>/dev/null || true
    pruned=$(( pruned + 1 ))
    log "pruned unreadable sentinel sid=${sid}"
    continue
  fi

  age=$(( now - stopped_at ))
  if [ "$age" -lt "$TTL" ]; then
    skipped=$(( skipped + 1 )); continue
  fi

  # Past TTL but the process is gone / recycled / not ours: prune the sentinel, never
  # signal. Signalling an unverified pid is the one way this sweep could hurt the box.
  if ! is_marked_claude "$pid" "$pid_start"; then
    rm -f "$sfile" 2>/dev/null || true
    pruned=$(( pruned + 1 ))
    log "pruned stale sentinel sid=${sid} pid=${pid} (process gone or no longer the marked claude)"
    continue
  fi

  log "closing sid=${sid} pid=${pid} age=${age}s (ttl=${TTL}s)"
  kill -TERM "$pid" 2>/dev/null || true
  kill_pids+=("$pid"); kill_starts+=("$pid_start"); kill_sids+=("$sid")
  closed=$(( closed + 1 ))
done

# Per-tick summary. Gen-1/gen-2's only symptom was "never reaps", invisible except as
# a permanently absent log line — so make every tick state its own outcome.
log "tick: seen=${seen} closed=${closed} skipped=${skipped} pruned=${pruned} ttl=${TTL}s"

# Escalate to SIGKILL for anything that ignored SIGTERM, then prune. Re-verify
# identity first: a pid that died on TERM and was recycled inside the grace window
# must not be KILLed. Terminal window + MCP node children exit with claude.
if [ "${#kill_pids[@]}" -gt 0 ]; then
  sleep "$TERM_GRACE"
  i=0
  while [ "$i" -lt "${#kill_pids[@]}" ]; do
    pid="${kill_pids[$i]}"
    if is_marked_claude "$pid" "${kill_starts[$i]}"; then
      kill -KILL "$pid" 2>/dev/null || true
      log "SIGKILL pid=${pid} (ignored SIGTERM)"
    fi
    rm -f "${STOPPED_DIR}/${kill_sids[$i]}.json" 2>/dev/null || true
    i=$(( i + 1 ))
  done
fi
exit 0
EOF
chmod 0755 "$TIDY_DEST"
log "session tidy installed: ${TIDY_DEST}"

# Oneshot service — runs as the agent user (so it can only signal its own uid, which
# is where claude runs) with the agent env, so an operator can override
# SB_SESSION_CLOSE_TTL_SEC (or set 0 to disable) in ~/.agent-env. EnvironmentFile is
# optional (leading '-') so a not-yet-populated env never blocks the timer. No
# After=network.target: the sweep is /proc + signals only and never touches the network.
cat > /etc/systemd/system/sb-session-tidy.service <<'EOF'
[Unit]
Description=SideButton finished Claude Code session tidy

[Service]
Type=oneshot
User=agent
EnvironmentFile=-/home/agent/.agent-env
ExecStart=/opt/sb-session-tidy.sh
EOF

# Timer — cadence mirrors sb-health / sb-registry-update (every 5 min). With a 60 min
# TTL that is ~12 samples per window, so a session closes within ~5 min of becoming
# eligible. The boot delay lets a rebooted box settle first.
cat > /etc/systemd/system/sb-session-tidy.timer <<'EOF'
[Unit]
Description=Run the SideButton session tidy at boot+5min and every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now sb-session-tidy.timer >/dev/null 2>&1 \
  || log "WARN: failed to enable sb-session-tidy.timer"
log "sb-session-tidy enabled (boot+5min, then every 5min; closes sessions ${SB_SESSION_CLOSE_TTL_SEC:-3600}s after their last Stop)"
