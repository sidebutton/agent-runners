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
# Why CPU-idle and not the on-disk transcript mtime: a box runs several sessions
# at once, and on this runtime Claude Code is NOT launched with a stable,
# discoverable session id — job-context.json's session_id differs from the
# transcript filename, and neither appears in the process cmdline/env — so a
# transcript file cannot be mapped back to its process. Per-PID CPU time is
# unambiguous: a finished TUI accrues no CPU, whereas any working session (even
# one streaming a long LLM turn or running a tool) advances utime+stime within a
# sampling window. The reaper samples CPU each tick and closes a session whose CPU
# has been flat for SB_SESSION_MAX_IDLE_SEC. The active job is doubly protected —
# it advances CPU, and if its job-context session id ever does appear in the
# cmdline that pid is skipped outright.
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
# Installed by agent-runners base/19e (SCRUM-1250). State lives under
# ~/.sidebutton and is keyed by pid+starttime, so a reboot (PIDs reset) or PID
# reuse can never make it target the wrong process.
set -uo pipefail

GRACE="${SB_SESSION_MAX_IDLE_SEC:-3600}"          # close a session idle this long (seconds) ~1h
TERM_GRACE="${SB_SESSION_TERM_GRACE_SEC:-10}"     # wait between SIGTERM and SIGKILL (seconds)
STATE_DIR="${HOME:-/home/agent}/.sidebutton"
STATE_FILE="${STATE_DIR}/session-reaper.state"    # one "pid starttime cpu_jiffies last_active_epoch" line per tracked session
LOG_FILE="${STATE_DIR}/session-reaper.log"
JOB_CONTEXT="${STATE_DIR}/job-context.json"

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

now="$(date +%s)"

# Active job session id — extra guard. On this runtime it may not appear in the
# cmdline, but when it does we never touch that session.
JOB_SID=""
[ -r "$JOB_CONTEXT" ] && JOB_SID="$(jq -r '.session_id // empty' "$JOB_CONTEXT" 2>/dev/null || true)"

# Load the previous snapshot into assoc arrays keyed by "pid:starttime".
declare -A PREV_CPU PREV_ACTIVE
if [ -r "$STATE_FILE" ]; then
  while read -r p st cpu la _rest; do
    [ -n "${p:-}" ] || continue
    PREV_CPU["$p:$st"]="$cpu"
    PREV_ACTIVE["$p:$st"]="$la"
  done < "$STATE_FILE"
fi

NEW_STATE="$(mktemp 2>/dev/null || echo "${STATE_FILE}.tmp")"
: > "$NEW_STATE"
reap_pids=()

# Only the reaper user's own Claude Code CLI processes (comm == "claude").
for pid in $(pgrep -u "$(id -u)" -x claude 2>/dev/null || true); do
  [ -r "/proc/$pid/stat" ] || continue

  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  # Skip non-session invocations (mcp helpers, version/doctor probes) — they are
  # short-lived and would exit long before the grace window anyway.
  case " $cmd " in
    *" mcp "*|*" --version "*|*" -v "*|*" doctor "*) continue ;;
  esac

  line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
  [ -n "$line" ] || continue
  # /proc/<pid>/stat: "pid (comm) state ppid pgrp ... utime stime ... starttime".
  # comm can contain spaces/parens, so strip up to the final ") " then index the
  # remaining fields: state=$1 … utime=$12 stime=$13 … starttime=$20.
  after="${line##*) }"
  # shellcheck disable=SC2086
  set -- $after
  starttime="${20:-0}"
  cpu=$(( ${12:-0} + ${13:-0} ))            # utime + stime, in clock ticks
  key="$pid:$starttime"

  prev_cpu="${PREV_CPU[$key]:-}"
  prev_active="${PREV_ACTIVE[$key]:-}"
  if [ -z "$prev_active" ]; then
    last_active="$now"                       # first time we see it → start the clock now
  elif [ -n "$prev_cpu" ] && [ "$cpu" -gt "$prev_cpu" ]; then
    last_active="$now"                       # CPU advanced since last tick → busy now
  else
    last_active="$prev_active"               # flat CPU → still idle, keep the clock
  fi

  # Never reap the active job session, even if it goes quiet.
  if [ -n "$JOB_SID" ] && printf '%s' "$cmd" | grep -qF -- "$JOB_SID"; then
    printf '%s %s %s %s\n' "$pid" "$starttime" "$cpu" "$now" >> "$NEW_STATE"
    continue
  fi

  idle=$(( now - last_active ))
  if [ "$idle" -ge "$GRACE" ]; then
    log "reaping pid=$pid idle=${idle}s cpu=${cpu}j cmd=$(printf '%.80s' "$cmd")"
    kill -TERM "$pid" 2>/dev/null || true
    reap_pids+=("$pid")                       # dropped from state — it is on its way out
  else
    printf '%s %s %s %s\n' "$pid" "$starttime" "$cpu" "$last_active" >> "$NEW_STATE"
  fi
done

mv -f "$NEW_STATE" "$STATE_FILE" 2>/dev/null || true

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
