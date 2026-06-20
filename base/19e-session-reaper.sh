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
# Idle signal is the session's on-disk transcript mtime (SCRUM-1354). Each session
# is now launched as `claude --session-id <uuid> …`, and its transcript is named
# ~/.claude/projects/*/<uuid>.jsonl, so a pid maps unambiguously to its transcript
# via the cmdline. A finished TUI stops writing its transcript; any working session
# (even one streaming a long LLM turn or running a tool) appends to it within
# seconds. idle = now − mtime; reap once idle ≥ SB_SESSION_MAX_IDLE_SEC.
#
# The earlier CPU-flatness heuristic (SCRUM-1250) never reaped anything: a finished
# Claude Code TUI holds ~1% CPU forever (Node event loop + MCP keepalives + Ink
# render loop), so utime+stime advanced on every tick, last_active reset every
# tick, and accrued idle never reached the threshold. It was only ever validated
# against stand-in processes (comm=claudezz) that genuinely go CPU-flat. The active
# job is still doubly protected — a fresh transcript keeps it alive, AND its
# job-context session id is skipped outright when present (it can be empty mid-run,
# so the fresh transcript is the primary guard, not this belt-and-suspenders skip).
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
# Installed by agent-runners base/19e (SCRUM-1250, rewritten SCRUM-1354).
#
# Idle is measured from the session's on-disk transcript mtime, located via the
# --session-id <uuid> in the process cmdline (~/.claude/projects/*/<uuid>.jsonl).
# This is stateless: idle = now − mtime each tick, no snapshot to carry across
# ticks. The previous pid+starttime/CPU state file is gone — a finished TUI never
# went CPU-flat (it holds ~1% CPU forever) so that signal never reaped anything.
set -uo pipefail

GRACE="${SB_SESSION_MAX_IDLE_SEC:-3600}"          # close a session idle this long (seconds) ~1h
TERM_GRACE="${SB_SESSION_TERM_GRACE_SEC:-10}"     # wait between SIGTERM and SIGKILL (seconds)
STATE_DIR="${HOME:-/home/agent}/.sidebutton"
LOG_FILE="${STATE_DIR}/session-reaper.log"
JOB_CONTEXT="${STATE_DIR}/job-context.json"
PROJECTS_DIR="${HOME:-/home/agent}/.claude/projects"

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

now="$(date +%s)"

# Active job session id — belt-and-suspenders only. It can be empty mid-run
# (observed on hamilton), so a fresh transcript is the primary guard, not this.
JOB_SID=""
[ -r "$JOB_CONTEXT" ] && JOB_SID="$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)"

reap_pids=()
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

  # No discoverable session id (operator/manual session): we cannot measure
  # idleness from a transcript and CPU flatness is invalid, so never reap. Skip.
  if [ -z "$sid" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  # Active job session — extra guard on top of the fresh-transcript check below.
  if [ -n "$JOB_SID" ] && [ "$sid" = "$JOB_SID" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  # Locate the transcript ~/.claude/projects/*/<uuid>.jsonl. No nullglob: an
  # unmatched glob stays literal and [ -e ] then fails, leaving transcript empty.
  transcript=""
  for f in "$PROJECTS_DIR"/*/"$sid".jsonl; do
    [ -e "$f" ] || continue
    transcript="$f"; break
  done
  # Session id present but no transcript yet (brand-new session): nothing to
  # measure, so leave it alone.
  if [ -z "$transcript" ]; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  mtime="$(stat -c %Y "$transcript" 2>/dev/null || echo 0)"
  idle=$(( now - mtime ))
  if [ "$idle" -ge "$GRACE" ]; then
    log "reaping pid=$pid sid=$sid idle=${idle}s transcript=$transcript"
    kill -TERM "$pid" 2>/dev/null || true
    reap_pids+=("$pid")
    reaped=$(( reaped + 1 ))
  fi
done

# Per-tick summary so a future "never reaps" regression is detectable from the
# log alone (the SCRUM-1250 bug's only symptom was a permanently absent log).
log "tick: seen=$seen reaped=$reaped skipped=$skipped grace=${GRACE}s"

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
