# 19e-session-reaper.sh — close stale Claude Code sessions (SCRUM-1250).
#
# A dispatched job launches Claude Code as an interactive TUI in a desktop
# terminal so an operator can watch the run on the live-desktop preview. When the
# session FINISHES it does not exit — it sits idle at the prompt. Over a box's
# lifetime these finished-but-running sessions pile up (the SCRUM-1250 screenshot
# is a 2x2 grid of idle "Bypass permissions…" TUIs), each holding RAM + file
# handles and cluttering the preview. This step installs a reaper that CLOSES a
# Claude Code session once it has been idle for ~1h after finishing — long enough
# for an operator to inspect the result on the live desktop, then reclaimed.
#
# Idle signal is a per-session "session-done" SENTINEL written by the stop hook at
# the genuine end of a run (SCRUM-1433). Each session is launched as
# `claude --session-id <uuid> …`; on its final Stop, base/14's claude-stop-hook.sh
# touches ~/.sidebutton/session-done/<uuid>, and a UserPromptSubmit hook
# (sb-clear-session-done.sh) REMOVES it the instant the session is re-engaged, so:
#   sentinel ABSENT  => never finished, or working again  => still running => skip
#   sentinel PRESENT => finished at mtime(sentinel); idle = now − mtime; reap at GRACE
# A pid maps to its sentinel via the --session-id <uuid> in its cmdline.
#
# Why a sentinel and not the transcript mtime (the SCRUM-1354 signal this replaces):
# transcript mtime tracks process LIVENESS, not task completion. An idle Claude TUI
# rewrites/touches its own transcript (Ink render + autosave) and operator steers
# (SCRUM-1384 POST /api/session/input) append to it, so mtime never goes stale and
# the reaper never reaped (seen=N reaped=0 forever). The sentinel is written ONCE at
# completion and is immune to every later transcript write. The even-earlier
# CPU-flatness heuristic (SCRUM-1250) failed for the same class of reason — a
# finished TUI holds ~1% CPU forever, so it never went flat. The active job is still
# doubly protected — no sentinel while it works, AND its job-context session id is
# skipped outright when present.
#
# Installed on every variant (all ship Claude Code); needs only claude + jq +
# systemd, no SB server, so it is NOT gated by SKIP_SIDEBUTTON_SERVER. It acts at
# 1h, well after idleRecovery (≤30m on the portal) has already released a job that
# is genuinely stuck, so the two never fight. Sourced-safe: never exits the
# installer — logs WARN and continues.

step "Step 19e/16: stale Claude Code session reaper (sb-session-reaper timer)"

REAPER_DEST="/opt/sb-session-reaper.sh"

cat > "$REAPER_DEST" <<'EOF'
#!/usr/bin/env bash
# /opt/sb-session-reaper.sh — close Claude Code sessions idle since they finished.
# Installed by agent-runners base/19e (SCRUM-1250, rewritten SCRUM-1354, SCRUM-1433).
#
# Idle is measured from a per-session "session-done" SENTINEL written by the stop
# hook at the session's genuine end (~/.sidebutton/session-done/<uuid>), matched to
# a live process via the --session-id <uuid> in its cmdline. Stateless: each tick,
# sentinel absent => still running (skip); present => idle = now − mtime(sentinel),
# reap at GRACE. The transcript-mtime signal it replaces (SCRUM-1354) tracked
# process liveness, not completion — an idle TUI and operator steers both keep the
# transcript fresh — so it never reaped. The sentinel is immune to all such writes.
set -uo pipefail

GRACE="${SB_SESSION_MAX_IDLE_SEC:-3600}"          # close a session idle this long (seconds) ~1h
TERM_GRACE="${SB_SESSION_TERM_GRACE_SEC:-10}"     # wait between SIGTERM and SIGKILL (seconds)
STATE_DIR="${HOME:-/home/agent}/.sidebutton"
LOG_FILE="${STATE_DIR}/session-reaper.log"
JOB_CONTEXT="${STATE_DIR}/job-context.json"
SESSION_DONE_DIR="${STATE_DIR}/session-done"      # SCRUM-1433: stop-hook completion sentinels, one file per finished session id

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

now="$(date +%s)"

# Active job session id — belt-and-suspenders only. It can be empty mid-run
# (observed on hamilton), so a fresh transcript is the primary guard, not this.
JOB_SID=""
[ -r "$JOB_CONTEXT" ] && JOB_SID="$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)"

reap_pids=()
live_sids=()                                       # SCRUM-1433: every live session id this tick, for the orphan-sentinel sweep
seen=0; reaped=0; skipped=0

# Only the reaper user's own Claude Code CLI processes (comm == "claude").
for pid in $(pgrep -u "$(id -u)" -x claude 2>/dev/null || true); do
  [ -r "/proc/$pid/cmdline" ] || continue

  # Skip non-session invocations (mcp helpers, version/doctor probes). Match the
  # SUBCOMMAND token (argv[1]) ONLY — not the whole cmdline — because a real
  # session carries its task prompt in argv, and a prompt that merely mentions
  # "mcp"/"doctor"/"-v" must never be mistaken for `claude mcp …` and left
  # un-reaped. These probes are short-lived and exit before the grace window
  # anyway, so this is only belt-and-suspenders.
  mapfile -d '' -t _argv < "/proc/$pid/cmdline" 2>/dev/null || _argv=()
  case "${_argv[1]:-}" in
    mcp|--version|-v|doctor) continue ;;
  esac

  seen=$(( seen + 1 ))

  # Pull --session-id <uuid> (or --session-id=<uuid>) out of argv.
  sid=""
  for (( i = 0; i < ${#_argv[@]}; i++ )); do
    case "${_argv[i]}" in
      --session-id)   sid="${_argv[i+1]:-}"; break ;;
      --session-id=*) sid="${_argv[i]#--session-id=}"; break ;;
    esac
  done

  # No discoverable session id (operator/manual session): no sentinel can be keyed
  # to it and CPU flatness is invalid, so never reap. Skip.
  if [ -z "$sid" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi
  live_sids+=("$sid")   # SCRUM-1433: this session is alive — its sentinel (if any) must not be swept as an orphan

  # Active job session — extra guard on top of the sentinel check below.
  if [ -n "$JOB_SID" ] && [ "$sid" = "$JOB_SID" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  # Idle from the session-done SENTINEL (SCRUM-1433), not the transcript mtime.
  # Absent => the session never reached its final Stop, or a UserPromptSubmit
  # cleared it because the session is working again => still running, never reap.
  sentinel="${SESSION_DONE_DIR}/${sid}"
  if [ ! -e "$sentinel" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  # Present => finished at the sentinel's mtime. The sentinel is touched once at
  # completion and never by later transcript writes, so this is real wall-clock idle.
  mtime="$(stat -c %Y "$sentinel" 2>/dev/null || echo 0)"
  idle=$(( now - mtime ))
  if [ "$idle" -ge "$GRACE" ]; then
    log "reaping pid=$pid sid=$sid idle=${idle}s sentinel=$sentinel"
    kill -TERM "$pid" 2>/dev/null || true
    reap_pids+=("$pid")
    reaped=$(( reaped + 1 ))
    rm -f "$sentinel" 2>/dev/null || true   # SCRUM-1433 AC4: clean up the sentinel after reaping
  fi
done

# Per-tick summary so a future "never reaps" regression is detectable from the
# log alone (the SCRUM-1250 bug's only symptom was a permanently absent log).
log "tick: seen=$seen reaped=$reaped skipped=$skipped grace=${GRACE}s"

# Orphan sentinel sweep (SCRUM-1433 AC4): a session-done file whose session has no
# live `claude` process anymore (it exited on its own, was killed out-of-band, or
# the box rebooted) is never revisited by the per-pid loop above, so it would
# linger forever. Drop any sentinel whose sid is not among the live session ids
# seen this tick. With no live sessions at all, every sentinel is an orphan.
if [ -d "$SESSION_DONE_DIR" ]; then
  for sfile in "$SESSION_DONE_DIR"/*; do
    [ -e "$sfile" ] || continue          # empty dir: the glob stays literal, [ -e ] fails
    sid_f="$(basename "$sfile")"
    alive=0
    for ls in "${live_sids[@]:-}"; do
      [ "$ls" = "$sid_f" ] && { alive=1; break; }
    done
    if [ "$alive" -eq 0 ]; then
      rm -f "$sfile" 2>/dev/null || true
      log "swept orphan sentinel sid=$sid_f (no live session)"
    fi
  done
fi

# Escalate to SIGKILL for anything that ignored SIGTERM.
if [ "${#reap_pids[@]}" -gt 0 ]; then
  sleep "$TERM_GRACE"
  for pid in "${reap_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      log "SIGKILL pid=$pid (ignored SIGTERM)"
    fi
  done
fi
exit 0
EOF
chmod 0755 "$REAPER_DEST"
log "session reaper installed: ${REAPER_DEST}"

# Oneshot service — runs as the agent user with the agent env (so an operator can
# override SB_SESSION_MAX_IDLE_SEC in ~/.agent-env). EnvironmentFile is optional
# (leading '-') so a not-yet-populated env never blocks the timer.
cat > /etc/systemd/system/sb-session-reaper.service <<'EOF'
[Unit]
Description=SideButton stale Claude Code session reaper
After=network.target

[Service]
Type=oneshot
User=agent
EnvironmentFile=-/home/agent/.agent-env
ExecStart=/opt/sb-session-reaper.sh
EOF

# Timer — first sweep 10min after boot, then every 10min. With a ~1h idle
# threshold that is ~6 samples per window: ample to tell a finished TUI from a
# working one, while reaping ~60-70min after a session actually goes idle.
cat > /etc/systemd/system/sb-session-reaper.timer <<'EOF'
[Unit]
Description=Run the SideButton session reaper at boot+10min and every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now sb-session-reaper.timer >/dev/null 2>&1 \
  || log "WARN: failed to enable sb-session-reaper.timer"
log "sb-session-reaper enabled (boot+10min, then every 10min; closes sessions idle >${SB_SESSION_MAX_IDLE_SEC:-3600}s)"
