#!/usr/bin/env bash
# base/tests/test-14-checkpoint.sh — regression guard for DEV-51 (SH-1): the transcript checkpoint.
#
# The Stop hook uploads a session's transcript only on its FINAL Stop, so every session killed before
# it (window closed, restart, PID gone — 109 of them in 30 days) left the portal nothing to resume.
# sb-checkpoint-transcript.sh uploads the running transcript from PostToolUse, and this guard pins the
# contract the ticket's definition of done states:
#   1. one checkpoint per window (300 s by default), however many tool calls — ten parallel ones too;
#   2. each one carries the transcript bytes of that moment, bytes=<raw> and checkpoint=1;
#   3. only the job session posts — another session, a sub-agent, a stopped session, a switched-off
#      box post nothing;
#   4. a portal answering 500 or hanging adds nothing to the tool call's latency and costs exactly one
#      usage-hook.log line per failed checkpoint;
#   5. the wiring (PostToolUse `.*`) and the final Stop upload, unchanged and still authoritative.
#
# Every case drives the REAL helper, extracted from base/14's heredoc, against a stub portal: a local
# HTTP server (fixtures/stub-portal.py, 127.0.0.1 only) that records each POST with its body gunzipped.
# Fake HOME, no live portal, no real ~/.sidebutton. Needs bash + jq; the POST cases need python3,
# gzip and curl, and the parallel case flock — each skips cleanly when its tool is missing.
# Run: bash base/tests/test-14-checkpoint.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
STUB_PORTAL="$SCRIPT_DIR/fixtures/stub-portal.py"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; return 1; }
skip() { printf 'skip - %s\n' "$1"; }
finish() { echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"; }

bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"
command -v jq >/dev/null 2>&1 || { skip "jq not installed — every assertion below needs it"; finish; }

# ── wiring ─────────────────────────────────────────────────────────────────────────────────────────
jq -e '.hooks.PostToolUse[] | select(.matcher == ".*") | .hooks[]
       | select(.command == "$HOME/.local/bin/sb-checkpoint-transcript.sh")' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json fires sb-checkpoint-transcript.sh on PostToolUse .*" \
  || bad "no PostToolUse .* entry for sb-checkpoint-transcript.sh — no checkpoint would ever run"
jq -e '[.hooks.PostToolUse[] | select(.matcher == ".*") | .hooks[]
        | select(.command | test("sb-checkpoint-transcript"))] | all(has("timeout") | not)' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "the checkpoint entry keeps the default hook timeout (the helper returns at once)" \
  || bad "the checkpoint entry carries a timeout — the helper must never need one"

TMP="$(mktemp -d)"
PORTAL_PID=""
cleanup() { [ -n "$PORTAL_PID" ] && kill "$PORTAL_PID" 2>/dev/null && wait "$PORTAL_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

awk "/cat > .*sb-checkpoint-transcript.sh.*<<'CKPTEOF'/{f=1;next} /^CKPTEOF\$/{f=0} f" "$HOOK" > "$TMP/ckpt.sh"
[ -s "$TMP/ckpt.sh" ] || { bad "could not extract sb-checkpoint-transcript.sh from base/14 (marker CKPTEOF moved?)"; finish; }
bash -n "$TMP/ckpt.sh" && ok "bash -n: sb-checkpoint-transcript.sh (the heredoc body parses)" \
  || { bad "sb-checkpoint-transcript.sh does not parse — every tool call would log a hook error"; finish; }
grep -q 'chmod +x "$AGENT_HOME/.local/bin/sb-checkpoint-transcript.sh"' "$HOOK" \
  && ok "base/14 makes the helper executable" || bad "base/14 never chmods the helper — the hook would not run"

# The final Stop upload stays exactly what it was: no checkpoint flag, and still gated to the main Stop.
awk "/cat > .*claude-stop-hook.sh.*<<'HOOKEOF'/{f=1;next} /^HOOKEOF\$/{f=0} f" "$HOOK" > "$TMP/stop.sh"
if grep -q 'api/jobs/transcript?job_id=${JOB_ID}&step_index=${STEP_INDEX}&session_id=${SESSION_ID}&bytes=${RAW_BYTES}"' "$TMP/stop.sh" \
   && ! grep -q 'checkpoint=1' "$TMP/stop.sh"; then
  ok "the Stop hook's final transcript upload is unchanged (no checkpoint flag) — it stays authoritative"
else
  bad "the Stop hook's final upload changed shape or carries a checkpoint flag"
fi

# The Stop hook stops a checkpoint upload of its session still in flight, right after writing the sentinel
# and before its own final upload — so no checkpoint can land after the final copy.
if awk '/if \[ "\$HOOK_EVENT" = "Stop" \]; then/{f=1} f && /mark_session_stopped "\$SESSION_ID"/{m=NR} f && m && /sb-checkpoint-transcript\.sh" --cancel "\$SESSION_ID"/{c=NR; exit} END{exit !(c && c > m)}' "$TMP/stop.sh" \
   && [ "$(grep -n 'sb-checkpoint-transcript.sh" --cancel' "$TMP/stop.sh" | head -1 | cut -d: -f1)" -lt "$(grep -n 'api/jobs/transcript?job_id' "$TMP/stop.sh" | head -1 | cut -d: -f1)" ]; then
  ok "the Stop hook cancels its session's in-flight checkpoint right after the sentinel, before the final upload"
else
  bad "the Stop hook does not cancel an in-flight checkpoint before its final upload"
fi

for t in python3 gzip curl; do
  command -v "$t" >/dev/null 2>&1 || { skip "$t not installed — the stub-portal cases need it"; finish; }
done

# ── sandbox: fake HOME, a job context, a transcript, the stub portal ────────────────────────────────
export HOME="$TMP/home"
SID="0b7c6a52-1d3e-4f5a-9b8c-7d6e5f4a3b21"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$HOME/.claude/projects/-home-agent-workspace/$SID/subagents"
cp "$TMP/ckpt.sh" "$HOME/.local/bin/sb-checkpoint-transcript.sh"; chmod +x "$HOME/.local/bin/sb-checkpoint-transcript.sh"
TR="$HOME/.claude/projects/-home-agent-workspace/$SID.jsonl"
SUB="$HOME/.claude/projects/-home-agent-workspace/$SID/subagents/agent-a1.jsonl"
printf '{"type":"user","sessionId":"%s","message":{"content":"go"}}\n' "$SID" > "$TR"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"sub"}]}}\n' > "$SUB"
job_context() { printf '{"job_id":4242,"step_index":1,"session_id":"%s","entry_path":"~/workspace"}\n' "$1" \
                  > "$HOME/.sidebutton/job-context.json"; }
job_context "$SID"

MODE_FILE="$TMP/portal.mode"; PLOG="$TMP/portal.log"; : > "$PLOG"; echo 200 > "$MODE_FILE"
python3 "$STUB_PORTAL" "$MODE_FILE" "$PLOG" > "$TMP/portal.port" 2>/dev/null &
PORTAL_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/portal.port" ] && break; sleep 0.1; done
PORT="$(head -1 "$TMP/portal.port" 2>/dev/null)"
[ -n "$PORT" ] || { bad "the stub portal did not start"; finish; }
agent_env() {  # $1 = extra lines
  printf 'AGENT_TOKEN=sb_test_token\nAGENT_NAME=agent-test\nPORTAL_URL=http://127.0.0.1:%s\nSB_CHECKPOINT_MAX_TIME_SEC=2\n%s' \
    "$PORT" "${1:-}" > "$HOME/.agent-env"
}
agent_env

LOG="$HOME/.sidebutton/usage-hook.log"
STAMP="$HOME/.sidebutton/last-checkpoint"
# PostToolUse input as Claude Code sends it; $2 adds fields (agent_id), $3 overrides transcript_path.
input() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -nc --arg sid "$1" --arg tp "${3:-$TR}" --argjson extra "$extra" \
    '{hook_event_name:"PostToolUse", session_id:$sid, transcript_path:$tp, cwd:"/home/agent/workspace",
      tool_name:"Bash", tool_use_id:"toolu_01", tool_input:{command:"ls"}, tool_response:{stdout:"x"}} + $extra'
}
# Fire the helper exactly as Claude Code does: hook JSON on stdin, a bare environment. Keeps its stdout.
fire() { printf '%s' "$1" | env -i PATH="$PATH" HOME="$HOME" bash "$HOME/.local/bin/sb-checkpoint-transcript.sh"; }
posts() { wc -l < "$PLOG" | tr -d ' '; }
wait_posts() { for _ in $(seq 1 40); do [ "$(posts)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
open_window() { echo $(( $(date +%s) - 301 )) > "$STAMP"; }
ms() { date +%s%3N; }

# ── 1. the first call of a session posts one checkpoint, carrying that moment's bytes ─────────────────
rm -f "$STAMP"
SNAP="$(cat "$TR")"; RAW="$(wc -c < "$TR" | tr -d ' ')"
OUT="$(fire "$(input "$SID")")"
[ -z "$OUT" ] && ok "the helper writes nothing to stdout (a PostToolUse hook's stdout is read by Claude Code)" \
  || bad "the helper printed to stdout: $OUT"
if wait_posts 1; then
  REC="$(tail -1 "$PLOG")"
  Q() { printf '%s' "$REC" | jq -r ".query.$1 // empty"; }
  [ "$(printf '%s' "$REC" | jq -r .path)" = "/api/jobs/transcript" ] && ok "POST /api/jobs/transcript (the existing route)" \
    || bad "posted to $(printf '%s' "$REC" | jq -r .path)"
  [ "$(Q checkpoint)" = 1 ] && ok "query carries checkpoint=1" || bad "no checkpoint=1 on the upload"
  [ "$(Q bytes)" = "$RAW" ] && ok "query carries bytes=<raw transcript size> ($RAW)" || bad "bytes=$(Q bytes), expected $RAW"
  [ "$(Q session_id)" = "$SID" ] && [ "$(Q job_id)" = 4242 ] && [ "$(Q step_index)" = 1 ] \
    && ok "query carries session_id + the job context's job_id / step_index" || bad "wrong identity in the query: $REC"
  [ "$(printf '%s' "$REC" | jq -r .headers.authorization)" = "Bearer sb_test_token" ] \
    && [ "$(printf '%s' "$REC" | jq -r '.headers["x-agent-name"]')" = "agent-test" ] \
    && [ "$(printf '%s' "$REC" | jq -r '.headers["content-type"]')" = "application/gzip" ] \
    && ok "agent token, X-Agent-Name and Content-Type: application/gzip are sent" || bad "headers wrong: $REC"
  [ "$(printf '%s' "$REC" | jq -r .body)" = "$SNAP" ] && ok "the gunzipped body IS the transcript as it was at that call" \
    || bad "the body differs from the transcript"
else
  bad "no checkpoint reached the stub portal"
fi
grep -q "checkpoint POST (${RAW}B raw): 200" "$LOG" 2>/dev/null && ok "the upload logs one line with its status" \
  || bad "no 'checkpoint POST' line in usage-hook.log"

# ── 2. the throttle: one per window ────────────────────────────────────────────────────────────────
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' >> "$TR"
fire "$(input "$SID")" >/dev/null; sleep 1; fire "$(input "$SID")" >/dev/null; sleep 0.8
[ "$(posts)" = 1 ] && ok "two more tool calls inside the window post nothing" || bad "posted $(posts) times inside one window"
# Inside a window the helper decides on builtins alone: a jq that records its calls sees none.
mkdir -p "$TMP/jqspy"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexec %s "$@"\n' "$TMP/jq.calls" "$(command -v jq)" > "$TMP/jqspy/jq"
chmod +x "$TMP/jqspy/jq"; : > "$TMP/jq.calls"
printf '%s' "$(input "$SID")" | env -i PATH="$TMP/jqspy:$PATH" HOME="$HOME" bash "$HOME/.local/bin/sb-checkpoint-transcript.sh" >/dev/null
[ ! -s "$TMP/jq.calls" ] && ok "a tool call inside the window runs no jq (the throttle comes before the input is parsed)" \
  || bad "an in-window call ran jq $(wc -l < "$TMP/jq.calls") time(s)"
mv "$HOME/.sidebutton/job-context.json" "$TMP/jc.hold"; : > "$TMP/jq.calls"; rm -f "$STAMP"
printf '%s' "$(input "$SID")" | env -i PATH="$TMP/jqspy:$PATH" HOME="$HOME" bash "$HOME/.local/bin/sb-checkpoint-transcript.sh" >/dev/null
[ ! -s "$TMP/jq.calls" ] && ok "with no job context (an operator box) a tool call leaves before any fork, even with no stamp at all" \
  || bad "a call with no job context ran jq $(wc -l < "$TMP/jq.calls") time(s)"
mv "$TMP/jc.hold" "$HOME/.sidebutton/job-context.json"; echo "$(date +%s)" > "$STAMP"; touch -d '1 minute ago' "$HOME/.sidebutton/job-context.json"
open_window
SNAP2="$(cat "$TR")"; RAW2="$(wc -c < "$TR" | tr -d ' ')"
# Claude Code is mid-append: the last record has no newline yet. Only complete lines are sent.
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"half-writt' >> "$TR"
fire "$(input "$SID")" >/dev/null
if wait_posts 2; then
  REC="$(tail -1 "$PLOG")"
  [ "$(printf '%s' "$REC" | jq -r .body)" = "$SNAP2" ] && [ "$(printf '%s' "$REC" | jq -r .query.bytes)" = "$RAW2" ] \
    && ok "300 s later the next call posts again — the grown transcript, bytes=$RAW2" \
    || bad "the second checkpoint does not carry the transcript of its moment"
  printf '%s' "$REC" | jq -e '.body | endswith("\n") and (contains("half-writt") | not)' >/dev/null \
    && ok "a torn last record (mid-append) is cut: the body is complete lines only, bytes= counts exactly them" \
    || bad "the checkpoint carried a torn last line"
else
  bad "no checkpoint once the window had expired"
fi
printf 'ten"}]}}\n' >> "$TR"

# A new dispatch rewrites job-context.json: its first checkpoint must not wait out the previous job's window.
before="$(posts)"; echo "$(date +%s)" > "$STAMP"; touch -d '10 seconds ago' "$STAMP"
job_context "$SID"   # rewritten now — newer than the stamp
fire "$(input "$SID")" >/dev/null
wait_posts $((before + 1)) && ok "a job context newer than the last checkpoint (a new dispatch) opens the window at once" \
  || bad "a new job inherited the previous job's window"
sleep 0.5

# ── 3. only the job session, only its main transcript, only before its Stop ─────────────────────────
# One case at a time, each given time to post before the next changes the sandbox: a wrongly launched
# upload re-checks the Stop sentinel just before its POST, so a sentinel created by the NEXT case would
# otherwise hide it.
gated() {  # $1 = label; the fire already happened
  sleep 0.6
  [ "$(posts)" = "$before" ] && ok "no checkpoint for $1" || bad "$1 posted a checkpoint: $(tail -1 "$PLOG" | jq -c .query)"
  before="$(posts)"
}
before="$(posts)"
open_window; fire "$(input "ffffffff-0000-4000-8000-000000000000")" >/dev/null; gated "another session while the job runs"
open_window; fire "$(input "$SID" '{"agent_id":"a1","agent_type":"general-purpose"}')" >/dev/null; gated "a sub-agent's tool call (agent_id)"
open_window; fire "$(input "$SID" '{}' "$SUB")" >/dev/null; gated "a call naming a sub-agent transcript (not <session_id>.jsonl)"
open_window; mkdir -p "$HOME/.sidebutton/session-stopped"; echo '{}' > "$HOME/.sidebutton/session-stopped/$SID.json"
stamp_before="$(cat "$STAMP")"
fire "$(input "$SID")" >/dev/null; gated "a session whose Stop sentinel exists (the final upload owns it)"
[ "$(cat "$STAMP")" = "$stamp_before" ] && ok "…and a stopped session's call does not even claim the window (the stamp is untouched)" \
  || bad "a stopped session's tool call consumed the checkpoint window"
rm -f "$HOME/.sidebutton/session-stopped/$SID.json"
open_window; mv "$HOME/.sidebutton/job-context.json" "$TMP/jc.bak"; fire "$(input "$SID")" >/dev/null
gated "a session with no job context (an operator window)"
printf '{"job_id":4242,"step_index":1}\n' > "$HOME/.sidebutton/job-context.json"; open_window; fire "$(input "$SID")" >/dev/null
gated "a job context that names no session (an old runtime) — the gate is strict: no session id, no checkpoint"
mv "$TMP/jc.bak" "$HOME/.sidebutton/job-context.json"
open_window; agent_env 'SB_CHECKPOINT_INTERVAL_SEC=0'; fire "$(input "$SID")" >/dev/null; gated "SB_CHECKPOINT_INTERVAL_SEC=0 (switched off)"
open_window; agent_env 'SB_CHECKPOINT_INTERVAL_SEC=off'; fire "$(input "$SID")" >/dev/null
gated "SB_CHECKPOINT_INTERVAL_SEC=off (not a number: off, never the default)"
open_window; agent_env; fire "$(input "../../etc")" >/dev/null; gated "a path-shaped session id"
open_window; fire "$(input "$SID")" >/dev/null
wait_posts $((before + 1)) && ok "…and the job session still posts once the gates are clear" \
  || bad "the job session stopped posting after the gate cases"

# ── 4. ten tool calls finishing at once share one window ───────────────────────────────────────────
if command -v flock >/dev/null 2>&1; then
  before="$(posts)"; open_window; pids=()
  # Wait on these ten only: a bare `wait` would also wait on the stub portal, which never exits.
  for _ in $(seq 1 10); do fire "$(input "$SID")" >/dev/null & pids+=("$!"); done; wait "${pids[@]}"
  sleep 1.5
  [ "$(posts)" = $((before + 1)) ] && ok "ten parallel tool calls in an open window post exactly one checkpoint" \
    || bad "ten parallel calls posted $(( $(posts) - before )) checkpoints"
else
  skip "flock not installed — the parallel-window case needs it"
fi
# Ten real processes rarely hit the microseconds between the unlocked check and the stamp, so the case
# above passes with or without the lock; the structure is what guarantees it. The stamp is written in
# exactly two places: under `flock -n 9` after a second check, or in the no-flock fallback.
if [ "$(grep -c '> "$STAMP"' "$TMP/ckpt.sh")" = 2 ] \
   && grep -q '( flock -n 9 || exit 1; _due && printf .%s\\n. "$NOW" > "$STAMP" )' "$TMP/ckpt.sh"; then
  ok "the stamp is taken under flock -n, re-checked inside the lock (one window, one claimant)"
else
  bad "the stamp write is no longer the locked re-check — parallel tool calls could each claim the window"
fi

# ── 5. a failing portal: no latency, one log line per failed checkpoint ────────────────────────────
for m in 500 hang; do
  echo "$m" > "$MODE_FILE"; open_window
  lines_before="$(grep -c 'checkpoint POST' "$LOG")"; before="$(posts)"
  t0="$(ms)"; fire "$(input "$SID")" >/dev/null; t1="$(ms)"
  [ $((t1 - t0)) -lt 1500 ] && ok "portal ${m}: the tool call's hook returns in $((t1 - t0)) ms (the upload is detached)" \
    || bad "portal ${m}: the hook took $((t1 - t0)) ms — the upload is in the tool call's path"
  if [ "$m" = hang ] && command -v setsid >/dev/null 2>&1; then
    upid=""; for _ in $(seq 1 20); do upid="$(pgrep -f -- "sb-checkpoint-transcript.sh --upload $SID" | head -1)"; [ -n "$upid" ] && break; sleep 0.1; done
    if [ -n "$upid" ] && [ "$(ps -o sid= -p "$upid" | tr -d ' ')" = "$upid" ] && [ "$(ps -o sid= -p "$upid" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ]; then
      ok "the upload in flight leads its own session (setsid): closing the job's window cannot hang it up"
    else
      bad "the upload is not in a session of its own (pid ${upid:-none})"
    fi
  fi
  wait_posts $((before + 1)) || bad "portal ${m}: the checkpoint never reached the stub"
  for _ in $(seq 1 60); do [ "$(grep -c 'checkpoint POST' "$LOG")" -gt "$lines_before" ] && break; sleep 0.1; done
  sleep 0.5
  new="$(( $(grep -c 'checkpoint POST' "$LOG") - lines_before ))"
  want="500"; [ "$m" = hang ] && want="000"
  [ "$new" = 1 ] && tail -1 "$LOG" | grep -q "checkpoint POST (.*B raw): ${want}\$" \
    && ok "portal ${m}: exactly one usage-hook.log line for the failed checkpoint ($(tail -1 "$LOG" | sed 's/^\[[^]]*\] //'))" \
    || bad "portal ${m}: ${new} log line(s) for one failed checkpoint"
  fire "$(input "$SID")" >/dev/null; sleep 0.5
  [ "$(posts)" = $((before + 1)) ] && ok "portal ${m}: the failure still spent the window — the next call does not retry" \
    || bad "portal ${m}: a failed checkpoint was retried inside its window"
done
echo 200 > "$MODE_FILE"

# ── 6. --cancel: the Stop hook's way to stop an upload still in flight ─────────────────────────────────
echo hang > "$MODE_FILE"; open_window; before="$(posts)"
fire "$(input "$SID")" >/dev/null; wait_posts $((before + 1))
upid="$(pgrep -f -- "sb-checkpoint-transcript.sh --upload $SID" | head -1)"
if [ -n "$upid" ] && [ -f "$HOME/.sidebutton/checkpoint-$SID.pid" ]; then
  bash "$HOME/.local/bin/sb-checkpoint-transcript.sh" --cancel "$SID"
  gone=0; for _ in $(seq 1 20); do kill -0 "$upid" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
  [ "$gone" = 1 ] && ! pgrep -f -- "sb-checkpoint-transcript.sh --upload $SID" >/dev/null \
    && tail -1 "$LOG" | grep -q 'still in flight at its Stop — cancelled' \
    && ok "--cancel stops this session's upload in flight (its whole process group) and logs it" \
    || bad "--cancel left the upload running (pid $upid)"
else
  bad "no upload in flight to cancel (pid file / process missing)"
fi
echo 200 > "$MODE_FILE"
sleep 30 & decoy=$!
echo "$decoy" > "$HOME/.sidebutton/checkpoint-$SID.pid"
bash "$HOME/.local/bin/sb-checkpoint-transcript.sh" --cancel "$SID"
kill -0 "$decoy" 2>/dev/null && ok "--cancel never signals a pid whose command line is not this session's upload (a recycled pid)" \
  || bad "--cancel killed an unrelated process"
kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null

# ── 7. overlapping uploads (a PostToolUse one still in flight when a StopFailure starts another) ─────────
# The pid file names the newest upload; one that ends must not remove it, or --cancel at the Stop could no
# longer reach the upload still running.
echo hang > "$MODE_FILE"; before="$(posts)"
env -i PATH="$PATH" HOME="$HOME" bash "$HOME/.local/bin/sb-checkpoint-transcript.sh" --upload "$SID" "$TR" 4242 1 </dev/null >/dev/null 2>&1 &
first=$!
wait_posts $((before + 1)) || bad "the first upload never reached the stub"
echo 999999 > "$HOME/.sidebutton/checkpoint-$SID.pid"   # the newer upload's pid
wait "$first" 2>/dev/null                                  # SB_CHECKPOINT_MAX_TIME_SEC=2: the first one gives up and exits
[ "$(cat "$HOME/.sidebutton/checkpoint-$SID.pid" 2>/dev/null)" = 999999 ] \
  && ok "an upload that ends removes the pid file only while it still names that upload — the newer one stays reachable for --cancel" \
  || bad "an ending upload removed the pid file a newer upload of its session had written"
rm -f "$HOME/.sidebutton/checkpoint-$SID.pid"
echo 200 > "$MODE_FILE"

finish
