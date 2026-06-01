#!/bin/bash
# /opt/report-health-snapshot.sh
#
# Collects agent health metrics, X11 screenshot, and Claude Code session log.
# Reports to sidebutton.com/api/agents/health-report.
#
# Usage: report-health-snapshot.sh [--full|--light|--auto]
#   --full   Metrics + screenshot + session log
#   --light  Metrics only
#   --auto   Full if active (Claude CPU>5%); if idle, full every 15min, skip in between
#
# Crontab:
#   */5 * * * * /opt/report-health-snapshot.sh --auto >>/tmp/health-snapshot.log 2>&1
#
# Requires: python3, curl, imagemagick (import), coreutils
# Agent env vars: SIDEBUTTON_AGENT_TOKEN, SIDEBUTTON_AGENT_NAME (from .agent-env)

set -uo pipefail

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
