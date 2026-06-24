#!/bin/bash
# /opt/report-health-snapshot.sh
#
# Collects agent health metrics, X11 screenshot, a per-session terminal-window
# crop, and the Claude Code session log. Reports to
# sidebutton.com/api/agents/health-report.
#
# Usage: report-health-snapshot.sh [--full|--light|--auto]
#   --full   Metrics + desktop screenshot + terminal-window crop + session log
#   --light  Metrics only
#   --auto   Full if active (Claude CPU>5%); if idle, full every 15min, skip in between
#
# Crontab:
#   */5 * * * * /opt/report-health-snapshot.sh --auto >>/tmp/health-snapshot.log 2>&1
#
# Requires: python3, curl, imagemagick (import), xdotool (window capture), coreutils
# Agent env vars: SIDEBUTTON_AGENT_TOKEN, SIDEBUTTON_AGENT_NAME (from .agent-env)

set -uo pipefail

# X display for the `import`/`xdotool` window capture. The sb-health.service unit
# sets DISPLAY=:10; default it here too so a cron/manual invocation (no unit env)
# still targets the agent desktop instead of failing to connect.
: "${DISPLAY:=:10}"; export DISPLAY

MODE="${1:---auto}"
# API_URL is derived from PORTAL_URL once .agent-env is sourced (see below).
export ENV_FILE="/home/agent/.agent-env"
STATE_FILE="/tmp/.health-snapshot-last"
TMP="/tmp/health-snapshot"
EVENTS_FILE="/home/agent/ops/logs/task-events.jsonl"

# ── Load agent env ───────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then echo "$(date -Is) ERROR: $ENV_FILE not found" >&2; exit 1; fi
set -a; source "$ENV_FILE"; set +a

# Portal endpoint — honour PORTAL_URL from .agent-env; default to the public host.
API_URL="${PORTAL_URL:-https://sidebutton.com}/api/agents/health-report"

if [ -z "${SIDEBUTTON_AGENT_TOKEN:-}" ] || [ -z "${SIDEBUTTON_AGENT_NAME:-}" ]; then
  echo "$(date -Is) ERROR: SIDEBUTTON_AGENT_TOKEN or SIDEBUTTON_AGENT_NAME not set" >&2; exit 1
fi

mkdir -p "$TMP"

# ── Session → window helpers (SCRUM-1414) ────────────────────────
# A dispatched job runs Claude Code in a desktop terminal launched (by the
# SideButton OSS GUI step) as:
#   xfce4-terminal --disable-server --title="Agent: <action>" \
#       -x tmux new-session -s sbjob-<session_id> claude --session-id <session_id> …
# so the active session's terminal is the xfce4-terminal whose argv carries
# `sbjob-<session_id>`. Titles are NON-unique across concurrent sessions, so we
# key on the session id, never the title. --disable-server ⇒ 1 process = 1 window.

# Echo the active Claude session id, or nothing. Primary source is the dispatch
# job-context (the id base/14 + base/19e also key on); fallback mirrors 19e — the
# running `claude --session-id <uuid>` whose transcript was written most recently.
resolve_active_session() {
  local jc="${HOME:-/home/agent}/.sidebutton/job-context.json" sid=""
  if [ -r "$jc" ]; then
    sid="$(jq -r '.session_id // empty' "$jc" 2>/dev/null || true)"
  fi
  if [ -n "$sid" ]; then printf '%s' "$sid"; return 0; fi

  local projects="${HOME:-/home/agent}/.claude/projects"
  local pid args cand transcript mt f best="" best_mt=0
  for pid in $(pgrep -u "$(id -u)" -x claude 2>/dev/null || true); do
    args="$(ps -ww -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *--session-id*) cand="$(printf '%s\n' "$args" \
        | sed -n 's/.*--session-id[ =]\([0-9a-fA-F][0-9a-fA-F-]\{34,35\}\).*/\1/p')" ;;
      *) cand="" ;;
    esac
    [ -n "$cand" ] || continue
    transcript=""
    for f in "$projects"/*/"$cand".jsonl; do [ -e "$f" ] || continue; transcript="$f"; break; done
    [ -n "$transcript" ] || continue
    mt="$(stat -c %Y "$transcript" 2>/dev/null || echo 0)"
    if [ "$mt" -gt "$best_mt" ]; then best_mt="$mt"; best="$cand"; fi
  done
  printf '%s' "$best"
}

# capture_terminal_window <session_id> <out.png> — crop that session's terminal
# window to <out.png>. Returns non-zero (writing nothing usable) on any miss so
# the caller cleanly omits the terminal frame; the desktop frame is unaffected.
capture_terminal_window() {
  local sid="$1" out="$2" pid term_pid="" wid
  command -v xdotool >/dev/null 2>&1 || return 1
  [ -n "$sid" ] || return 1
  for pid in $(pgrep -u "$(id -u)" -f "sbjob-${sid}" 2>/dev/null || true); do
    case "$(ps -ww -o comm= -p "$pid" 2>/dev/null || true)" in
      xfce4-terminal) term_pid="$pid"; break ;;
    esac
  done
  [ -n "$term_pid" ] || return 1
  wid="$(xdotool search --pid "$term_pid" 2>/dev/null | head -n1 || true)"
  [ -n "$wid" ] || return 1
  import -window "$wid" png:"$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  return 0
}

# ── Activity detection ───────────────────────────────────────────
export CLAUDE_CPU=$(ps aux 2>/dev/null | awk '/[c]laude/ {s+=$3} END {printf "%d",s+0}')
export ACTIVITY="idle"
[ "${CLAUDE_CPU:-0}" -gt 5 ] 2>/dev/null && export ACTIVITY="active"

# ── Auto mode: decide full/light/skip ────────────────────────────
if [ "$MODE" = "--auto" ]; then
  if [ "$ACTIVITY" = "active" ]; then
    MODE="--full"
  elif [ -f "$STATE_FILE" ]; then
    ELAPSED=$(( $(date +%s) - $(cat "$STATE_FILE") ))
    if [ "$ELAPSED" -lt 900 ]; then
      exit 0  # idle + reported <15min ago → skip
    fi
    MODE="--full"
  else
    MODE="--full"  # first run
  fi
fi

# ── System metrics (always collected) ────────────────────────────
export CPU_PCT=$(top -bn1 2>/dev/null | awk '/Cpu\(s\)/ {printf "%.1f",$2+$4}' || echo "0")
export MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo "0")
export MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "0")
export SWAP_USED=$(free -m 2>/dev/null | awk '/Swap:/ {print $3}' || echo "0")
export SWAP_TOTAL=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}' || echo "0")
export LOAD_1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
export LOAD_5=$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo "0")
export LOAD_15=$(awk '{print $3}' /proc/loadavg 2>/dev/null || echo "0")
export DISK_PCT=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo "0")
export UPTIME_SEC=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null || echo "0")

# Process checks
export SB_STATUS=$(systemctl is-active sidebutton 2>/dev/null || echo "unknown")
export CHROME_COUNT=$(pgrep -c -f '[c]hrom' 2>/dev/null || true)
export CLAUDE_COUNT=$(pgrep -c -f '[c]laude' 2>/dev/null || true)
[ -z "$CHROME_COUNT" ] && export CHROME_COUNT=0
[ -z "$CLAUDE_COUNT" ] && export CLAUDE_COUNT=0

# ── Screenshot via SideButton Chrome extension (full mode only) ──
export SS_FILE="$TMP/screenshot.png"
rm -f "$SS_FILE"
if [ "$MODE" = "--full" ]; then
  SS_JSON=$(curl -sf --max-time 10 http://localhost:9876/api/screenshot 2>/dev/null || true)
  if [ -n "$SS_JSON" ]; then
    echo "$SS_JSON" | python3 -c '
import sys, json, base64
d = json.load(sys.stdin)
b64 = d.get("screenshot_b64", "")
if b64:
    with open(sys.argv[1], "wb") as f:
        f.write(base64.b64decode(b64))
' "$SS_FILE" 2>/dev/null || true
  fi
fi

# ── Terminal-window crop for the active session (full mode only; SCRUM-1414) ──
# Resolve the active session id (also sent on its own so the portal can key the
# desktop frame), then crop that session's Claude Code window. Every hop degrades
# to "omit terminal frame": no session / no xdotool / no window / empty file all
# leave terminal_b64 absent while metrics + the desktop screenshot still post.
export SESSION_ID=""
export TERM_FILE="$TMP/terminal.png"
rm -f "$TERM_FILE"
if [ "$MODE" = "--full" ]; then
  SESSION_ID="$(resolve_active_session || true)"
  if [ -n "$SESSION_ID" ]; then
    capture_terminal_window "$SESSION_ID" "$TERM_FILE" || rm -f "$TERM_FILE"
  fi
fi

# ── Session log (full mode only) ─────────────────────────────────
export SESSION_FILE="$TMP/session.txt"
rm -f "$SESSION_FILE"
if [ "$MODE" = "--full" ] && [ -f "$EVENTS_FILE" ]; then
  tail -50 "$EVENTS_FILE" > "$SESSION_FILE" 2>/dev/null || true
fi

# ── Build JSON payload (Python for safe escaping) ────────────────
export PAYLOAD_FILE="$TMP/payload.json"

python3 - << 'PYEOF'
import json, base64, os

def env(k, default="0"):
    v = os.environ.get(k, default)
    return v if v else default

payload = {
    "metrics": {
        "cpu_pct": float(env("CPU_PCT")),
        "mem_used_mb": int(env("MEM_USED")),
        "mem_total_mb": int(env("MEM_TOTAL")),
        "swap_used_mb": int(env("SWAP_USED")),
        "swap_total_mb": int(env("SWAP_TOTAL")),
        "load_1m": float(env("LOAD_1")),
        "load_5m": float(env("LOAD_5")),
        "load_15m": float(env("LOAD_15")),
        "disk_pct": int(env("DISK_PCT")),
        "uptime_sec": int(env("UPTIME_SEC")),
    },
    "processes": {
        "sidebutton": env("SB_STATUS", "unknown"),
        "chrome_count": int(env("CHROME_COUNT")),
        "claude_code_count": int(env("CLAUDE_COUNT")),
        "claude_code_cpu": int(env("CLAUDE_CPU")),
    },
    "activity": env("ACTIVITY", "unknown"),
}

# Screenshot (base64-encoded PNG)
ss = os.environ.get("SS_FILE", "")
if ss and os.path.isfile(ss) and os.path.getsize(ss) > 0:
    with open(ss, "rb") as f:
        payload["screenshot_b64"] = base64.b64encode(f.read()).decode()

# Terminal-window crop (base64-encoded PNG) — only when a frame was captured
# (xdotool present, session resolved, window found). Absent otherwise. (SCRUM-1414)
tf = os.environ.get("TERM_FILE", "")
if tf and os.path.isfile(tf) and os.path.getsize(tf) > 0:
    with open(tf, "rb") as f:
        payload["terminal_b64"] = base64.b64encode(f.read()).decode()

# Active Claude session id — keys the terminal (and desktop) frame to a session.
sid = os.environ.get("SESSION_ID", "")
if sid:
    payload["session_id"] = sid

# Session log (plain text, last 50 lines of task events)
sf = os.environ.get("SESSION_FILE", "")
if sf and os.path.isfile(sf) and os.path.getsize(sf) > 0:
    with open(sf) as f:
        payload["session_log"] = f.read()

# Agent env (syncs .agent-env to portal DB, strip 'export ' prefix for clean storage)
env_file = os.environ.get("ENV_FILE", "")
if env_file and os.path.isfile(env_file):
    with open(env_file) as f:
        lines = []
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('export '):
                line = line[7:]
            lines.append(line)
        payload["agent_env"] = '\n'.join(lines)

# .mcp.json (syncs MCP server config to portal DB)
import pathlib
for mcp_path in [pathlib.Path.home() / "workspace" / ".mcp.json",
                 pathlib.Path("/home/agent/workspace/.mcp.json")]:
    if mcp_path.is_file():
        try:
            payload["mcp_json"] = json.loads(mcp_path.read_text())
        except Exception:
            pass
        break

with open(os.environ["PAYLOAD_FILE"], "w") as out:
    json.dump(payload, out)
PYEOF

# ── POST to website ──────────────────────────────────────────────
if [ -f "$PAYLOAD_FILE" ]; then
  HTTP=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$API_URL" \
    -H "Authorization: Bearer $SIDEBUTTON_AGENT_TOKEN" \
    -H "X-Agent-Name: $SIDEBUTTON_AGENT_NAME" \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD_FILE" \
    --max-time 30 2>/dev/null || echo "000")

  if [ "$HTTP" = "200" ]; then
    date +%s > "$STATE_FILE"
    echo "$(date -Is) OK mode=$MODE activity=$ACTIVITY cpu=$CPU_PCT mem=$MEM_USED/$MEM_TOTAL"
  else
    echo "$(date -Is) FAIL http=$HTTP mode=$MODE" >&2
  fi
fi

# ── Cleanup temp files ───────────────────────────────────────────
rm -rf "$TMP"
