#!/usr/bin/env bash
# base/tests/test-14j-stop-pending-background.sh — regression guard for DEV-181: a Stop whose session still
# waits on background work is a pause, not the end of the job.
#
# Claude Code fires Stop at every turn end, including a turn that ends only to wait for a forked skill
# (/code-review), an async Agent, a background Bash or a scheduled wakeup. The Stop hook used to complete the
# job at that Stop (usage final=true + step-complete), so the playbook gate ran before the verdict comment
# existed (KURABU runs 3010/3012/3013, 2026-09-28). This guard pins the contract that replaced it:
#   1. the work comes from the Stop stdin (background_tasks, session_crons — Claude Code 2.1.28x), replayed
#      from 17 events two live 2.1.281 sessions sent (fixtures/dev-181-live-stop-payloads.json), and from a
#      notification already queued in the transcript;
#   2. a deferred Stop posts usage final=false, NO step-complete, no final transcript, drains no artifacts,
#      writes no session-tidy sentinel; it logs what it waits for, leaves stop-deferred-<sid>, and starts a
#      checkpoint=1 upload (job session only, the per-box switch honoured);
#   3. the Stop after the work returned completes exactly as before — once — with output_message taken from
#      stdin last_assistant_message (the transcript does not hold the closing text yet);
#   4. what does NOT hold a job: a recurring cron, the ambient kinds (dream, auto-mode scan), an unknown kind,
#      a finished task, a stale queue entry, a CLI that sends neither field (the old contract, unchanged);
#   5. SubagentStop and non-job sessions post exactly what they did; the hook exits 0 on every path;
#   6. AC5: the whole hook on a 3 MB transcript stays under 5 s.
#
# Every case drives the REAL hook and checkpoint helper, extracted from base/14's heredocs, under `env -i`
# with a fake HOME, a `claude`-named parent (the sentinel's ancestor walk) and the stub portal
# (fixtures/stub-portal.py, 127.0.0.1 only) that records every POST. Needs bash + jq; the POST cases need
# python3 + curl + gzip. Run: bash base/tests/test-14j-stop-pending-background.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
STUB_PORTAL="$SCRIPT_DIR/fixtures/stub-portal.py"
LIVE="$SCRIPT_DIR/fixtures/dev-181-live-stop-payloads.json"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; return 1; }
skip() { printf 'skip - %s\n' "$1"; }
finish() { echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"; }

bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"
command -v jq >/dev/null 2>&1 || { skip "jq not installed — every assertion below needs it"; finish; }

# ── wiring ─────────────────────────────────────────────────────────────────────────────────────────
for ev in Stop SubagentStop; do
  jq -e --arg ev "$ev" '.hooks[$ev][] | .hooks[] | select(.command == "$HOME/.local/bin/claude-stop-hook.sh")' \
    "$HOOKS_JSON" >/dev/null 2>&1 \
    && ok "claude-hooks.json runs claude-stop-hook.sh on $ev" || bad "$ev no longer runs claude-stop-hook.sh"
done
jq -e '[.hooks.Stop[] | .hooks[] | select(has("timeout"))] | length == 0' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "the Stop entry keeps no blocking timeout — deferring needs no decision:block, the hook still returns at once" \
  || bad "the Stop entry grew a timeout"

TMP="$(mktemp -d)"
PORTAL_PID=""
cleanup() { [ -n "$PORTAL_PID" ] && kill "$PORTAL_PID" 2>/dev/null && wait "$PORTAL_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

extract() {  # $1=basename  $2=heredoc marker
  awk "/cat > .*$1.*<<'$2'/{f=1;next} /^$2\$/{f=0} f" "$HOOK" > "$TMP/$1"
  [ -s "$TMP/$1" ] || { bad "could not extract $1 from base/14 (heredoc marker $2 moved?)"; return 1; }
  bash -n "$TMP/$1" && ok "bash -n: $1 (the heredoc body parses)" || bad "$1 does not parse"
}
extract claude-stop-hook.sh HOOKEOF || finish
extract sb-checkpoint-transcript.sh CKPTEOF || finish

# The completing Stop is the ONLY place step-complete, the final transcript, the drain and the sentinel live.
STOPSH="$TMP/claude-stop-hook.sh"
grep -q '^if \[ "\$HOOK_EVENT" = "Stop" \] && \[ -z "\$PENDING" \]; then IS_FINAL=true; else IS_FINAL=false; fi$' "$STOPSH" \
  && ok "usage final=true only for a Stop with nothing pending (the portal completes the step on final=true alone)" \
  || bad "final=true is no longer gated on PENDING"
awk '/stop_pending_work 2>\/dev\/null \|\| true/{p=NR} /mark_session_stopped "\$SESSION_ID" \|\| true/{m=NR} /!= job session \$JOB_SID/{g=NR}
     END{exit !(p && m && g && p < m && m < g)}' "$STOPSH" \
  && ok "pending work is read before the sentinel, and the sentinel still lands before the job-session gate" \
  || bad "the order PENDING -> sentinel -> job-session gate is broken"

for t in python3 curl gzip; do
  command -v "$t" >/dev/null 2>&1 || { skip "$t not installed — the stub-portal cases need it"; finish; }
done
[ -f "$LIVE" ] || { bad "fixture missing: $LIVE"; finish; }

# ── sandbox: fake HOME, the helpers, a claude parent, the stub portal ───────────────────────────────
export HOME="$TMP/home"
mkdir -p "$HOME/.sidebutton" "$HOME/.local/bin" "$HOME/workspace/artifacts" "$TMP/claude-bin"
cp "$STOPSH" "$TMP/sb-checkpoint-transcript.sh" "$HOME/.local/bin/"; chmod +x "$HOME/.local/bin"/*.sh
CLAUDE_SH="$TMP/claude-bin/claude"; cp "$(command -v bash)" "$CLAUDE_SH"
MODE_FILE="$TMP/portal.mode"; PLOG="$TMP/portal.log"; : > "$PLOG"; echo 200 > "$MODE_FILE"
python3 "$STUB_PORTAL" "$MODE_FILE" "$PLOG" > "$TMP/portal.port" 2>/dev/null &
PORTAL_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/portal.port" ] && break; sleep 0.1; done
PORT="$(head -1 "$TMP/portal.port" 2>/dev/null)"
[ -n "$PORT" ] || { bad "the stub portal did not start"; finish; }
agent_env() {  # $1 = extra lines
  printf 'AGENT_TOKEN=sb_test_token\nAGENT_NAME=agent-test\nPORTAL_URL=http://127.0.0.1:%s\n%s' "$PORT" "${1:-}" \
    > "$HOME/.agent-env"
}
agent_env
LOG="$HOME/.sidebutton/usage-hook.log"; : > "$LOG"
job_context() { printf '{"job_id":181,"step_index":0,"session_id":"%s","entry_path":"~/workspace"}\n' "$1" \
                  > "$HOME/.sidebutton/job-context.json"; }

tr_path() { printf '%s/.claude/projects/-home-agent-workspace/%s.jsonl' "$HOME" "$1"; }
# A main transcript as the Stop hook finds it: the prompt, one tool call and its result, a closing text that
# is NOT the turn's final one (that is what the live sessions showed — the closing text lands after the hook).
new_transcript() {  # $1 = session id
  local tp; tp="$(tr_path "$1")"; mkdir -p "$(dirname "$tp")"
  jq -nc --arg s "$1" '
    {type:"user", sessionId:$s, message:{role:"user", content:"review the branch"}},
    {type:"assistant", sessionId:$s, message:{model:"claude-opus-5-5", usage:{input_tokens:10, output_tokens:5},
      content:[{type:"tool_use", id:"toolu_01", name:"Skill", input:{skill:"code-review"}}]}},
    {type:"user", sessionId:$s, message:{role:"user", content:[{type:"tool_result", tool_use_id:"toolu_01",
      content:"Skill \"code-review\" launched (forked execution, running in the background)."}]}},
    {type:"assistant", sessionId:$s, message:{model:"claude-opus-5-5", usage:{input_tokens:3, output_tokens:2},
      content:[{type:"text", text:"PREVIOUS-TURN-TEXT"}]}}' > "$tp"
}
queue_op() {  # $1 sid  $2 operation  $3 content ('' = none)  $4 reason ('' = none) — a record as 2.1.281 writes it
  jq -nc --arg s "$1" --arg op "$2" --arg c "${3:-}" --arg r "${4:-}" \
    '{type:"queue-operation", operation:$op, timestamp:"2026-09-29T20:08:26.334Z", sessionId:$s}
     + (if $c != "" then {content:$c} else {} end) + (if $r != "" then {reason:$r} else {} end)' >> "$(tr_path "$1")"
}
notif() { printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n<status>completed</status>\n<summary>Agent "slow probe" completed</summary>\n</task-notification>' "$1"; }
tool_call() {  # $1 sid — one more tool call in the transcript (a later turn)
  jq -nc --arg s "$1" '{type:"assistant", sessionId:$s, message:{model:"claude-opus-5-5",
      content:[{type:"tool_use", id:"toolu_02", name:"Bash", input:{command:"ls"}}]}}' >> "$(tr_path "$1")"
}
# Stop / SubagentStop stdin. $3 = background_tasks JSON, $4 = session_crons JSON; '-' for $3 omits BOTH
# fields (a CLI before 2.1.28x). $5 = last_assistant_message.
input() {
  local ev="$1" sid="$2" bg="${3:-[]}" crons="${4:-[]}" lam="${5:-}"
  jq -nc --arg ev "$ev" --arg sid "$sid" --arg tp "$(tr_path "$sid")" --arg cwd "$HOME/workspace" \
    --arg bg "$bg" --arg crons "$crons" --arg lam "$lam" '
    {session_id:$sid, transcript_path:$tp, cwd:$cwd, permission_mode:"bypassPermissions",
     hook_event_name:$ev, stop_hook_active:false, last_assistant_message:$lam}
    + (if $bg == "-" then {} else {background_tasks:($bg | fromjson), session_crons:($crons | fromjson)} end)
    + (if $ev == "SubagentStop" then {agent_id:"a1b2c3", agent_type:"general-purpose"} else {} end)'
}

# Fire the hook exactly as Claude Code does: a `claude` process -> a shell -> the hook, stdin = the hook JSON,
# a bare environment. Snapshots what reached the portal into $TMP/last.jsonl; RC = the hook's exit code.
fire() {  # $1 = stdin JSON  $2 = wait for a checkpoint upload? (1 = yes)
  local before; before="$(wc -l < "$PLOG" | tr -d ' ')"
  rm -rf "$HOME/.sidebutton/session-stopped"
  printf '%s' "$1" | env -i HOME="$HOME" PATH="$PATH" "$CLAUDE_SH" \
    -c 'exec 3<&0; bash "$0" <&3; echo $? > "$1"; :' "$HOME/.local/bin/claude-stop-hook.sh" "$TMP/rc" >/dev/null 2>&1
  RC="$(cat "$TMP/rc" 2>/dev/null || echo x)"
  if [ "${2:-0}" = 1 ]; then
    for _ in $(seq 1 50); do
      tail -n +"$((before + 1))" "$PLOG" | jq -e 'select(.query.checkpoint == "1")' >/dev/null 2>&1 && break
      sleep 0.1
    done
  else
    sleep 0.3   # a checkpoint that should not exist gets the time to show up anyway
  fi
  tail -n +"$((before + 1))" "$PLOG" > "$TMP/last.jsonl"
}
# What the last fire sent, one fact each.
usage_final() { jq -r 'select(.path == "/api/jobs/usage") | .body | fromjson | .final' "$TMP/last.jsonl" | paste -sd, -; }
sc_count()    { jq -r 'select(.path == "/api/jobs/step-complete") | .path' "$TMP/last.jsonl" | wc -l | tr -d ' '; }
sc_msg()      { jq -r 'select(.path == "/api/jobs/step-complete") | .body | fromjson | .output_message' "$TMP/last.jsonl"; }
transcripts() { jq -r 'select(.path == "/api/jobs/transcript") | if .query.checkpoint == "1" then "checkpoint" else "final" end' \
                  "$TMP/last.jsonl" | paste -sd, -; }
artifacts()   { jq -r 'select(.path == "/api/jobs/artifacts") | .query.filename' "$TMP/last.jsonl" | paste -sd, -; }
nposts()      { wc -l < "$TMP/last.jsonl" | tr -d ' '; }
sentinel()    { [ -f "$HOME/.sidebutton/session-stopped/$1.json" ]; }
marker()      { printf '%s/.sidebutton/stop-deferred-%s' "$HOME" "$1"; }

# A deferred Stop, in full. $1 = label, $2 = sid, $3 = the pending text the log must name.
expect_deferred() {
  local label="$1" sid="$2" what="$3" good=1
  [ "$RC" = 0 ] || { bad "$label: the hook exited $RC"; good=0; }
  [ "$(usage_final)" = false ] || { bad "$label: usage final=$(usage_final), expected false (final=true alone completes the step)"; good=0; }
  [ "$(sc_count)" = 0 ] || { bad "$label: step-complete was POSTed — the job would close before its verdict"; good=0; }
  sentinel "$sid" && { bad "$label: the session-tidy sentinel was written for a session still waiting"; good=0; }
  case ",$(transcripts)," in *,final,*) bad "$label: the FINAL transcript was uploaded (its closing text would become the step summary)"; good=0 ;; esac
  [ -z "$(artifacts)" ] || { bad "$label: artifacts were drained mid-run: $(artifacts)"; good=0; }
  grep -qF "deferred step-complete: pending ${what} (job 181 step 0 session ${sid})" "$LOG" \
    || { bad "$label: no 'deferred step-complete: pending ${what}' line in usage-hook.log"; good=0; }
  grep -qF "$what" "$(marker "$sid")" 2>/dev/null || { bad "$label: stop-deferred-$sid does not record '$what'"; good=0; }
  [ "$good" = 1 ] && ok "$label: DEFERRED — usage final=false, no step-complete, no sentinel, no final transcript, no drain; logged + marked ($what)"
}
# A completing Stop, in full. $1 = label, $2 = sid, $3 = the expected output_message.
expect_completed() {
  local label="$1" sid="$2" msg="$3" good=1
  [ "$RC" = 0 ] || { bad "$label: the hook exited $RC"; good=0; }
  [ "$(usage_final)" = true ] || { bad "$label: usage final=$(usage_final), expected true"; good=0; }
  [ "$(sc_count)" = 1 ] || { bad "$label: step-complete POSTed $(sc_count) times, expected exactly once"; good=0; }
  [ "$(sc_msg)" = "$msg" ] || { bad "$label: output_message '$(sc_msg)', expected '$msg'"; good=0; }
  [ "$(transcripts)" = final ] || { bad "$label: transcript uploads '$(transcripts)', expected one final upload"; good=0; }
  sentinel "$sid" || { bad "$label: no session-tidy sentinel at the completing Stop"; good=0; }
  [ -e "$(marker "$sid")" ] && { bad "$label: stop-deferred-$sid survived the completing Stop"; good=0; }
  [ "$good" = 1 ] && ok "$label: COMPLETED once — final=true, step-complete (output_message '$msg'), final transcript, sentinel"
}

# ── 1. replay: the 17 hook events two live Claude Code 2.1.281 sessions sent ──────────────────────────
# ab: a background Bash (40 s) + an async Agent (75 s). c: a background-forked skill + a one-shot cron.
replay() {  # $1 = label prefix of the events to replay, in order
  jq -c --arg p "$1" '.events[] | select(.label | startswith($p))' "$LIVE"
}
declare -A WANT=(
  ["ab 20:06:44 Stop"]="completed"
  ["ab 20:07:06 Stop"]="deferred:shell by5s77k3p, subagent ac5e047f7f903d022"
  ["ab 20:07:46 Stop"]="deferred:subagent ac5e047f7f903d022"
  ["ab 20:08:26 Stop"]="completed"
  ["ab 20:08:30 Stop"]="completed"
  ["c 20:19:33 Stop"]="deferred:subagent a7e3b62bf106bfced, cron 8498e328"
  ["c 20:20:33 Stop"]="deferred:cron 8498e328"
  ["c 20:21:02 Stop"]="completed"
)
for sess in "ab " "c "; do
  while IFS= read -r ev; do
    label="$(printf '%s' "$ev" | jq -r .label)"
    sid="$(printf '%s' "$ev" | jq -r .stdin.session_id)"
    job_context "$sid"; [ -f "$(tr_path "$sid")" ] || new_transcript "$sid"
    stdin="$(printf '%s' "$ev" | jq -c --arg tp "$(tr_path "$sid")" --arg cwd "$HOME/workspace" \
               '.stdin | .transcript_path = $tp | .cwd = $cwd')"
    lam="$(printf '%s' "$stdin" | jq -r '.last_assistant_message // ""')"
    case "${WANT[$label]:-subagent}" in
      deferred:*) fire "$stdin" 1; expect_deferred "live $label" "$sid" "${WANT[$label]#deferred:}" ;;
      completed)  fire "$stdin"; expect_completed "live $label" "$sid" "$lam" ;;
      subagent)
        fire "$stdin"
        if [ "$RC" = 0 ] && [ "$(usage_final)" = false ] && [ "$(nposts)" = 1 ] && ! sentinel "$sid"; then
          ok "live $label: usage final=false only — nothing else, whatever background_tasks says"
        else
          bad "live $label: SubagentStop changed: rc=$RC final=$(usage_final) posts=$(nposts)"
        fi ;;
    esac
  done < <(replay "$sess")
done

# ── 2. the job-21261 shape: /code-review forked at 18:19, back at 18:28 ────────────────────────────
SID="9e3f2c1a-5b7d-4e8f-a6c4-181018190421"
job_context "$SID"; new_transcript "$SID"; : > "$LOG"
printf 'screenshot-bytes' > "$HOME/workspace/artifacts/review-evidence.png"
FORK='[{"id":"a04a903e0cb039115","type":"subagent","status":"running","description":"/code-review","agent_type":"general-purpose"}]'
fire "$(input Stop "$SID" "$FORK" '[]' 'Code review launched in the background; I will post the verdict when it returns.')" 1
expect_deferred "run-3012 shape, 18:19 Stop (fork running)" "$SID" "subagent a04a903e0cb039115"
CK="$(jq -c 'select(.path == "/api/jobs/transcript")' "$TMP/last.jsonl" | tail -1)"
if [ -n "$CK" ] && [ "$(printf '%s' "$CK" | jq -r '.query.checkpoint')" = 1 ] \
   && [ "$(printf '%s' "$CK" | jq -r '.query.session_id')" = "$SID" ] && [ "$(printf '%s' "$CK" | jq -r '.query.job_id')" = 181 ] \
   && [ "$(printf '%s' "$CK" | jq -r '.body')" = "$(cat "$(tr_path "$SID")")" ]; then
  ok "…and it uploads the running transcript as checkpoint=1 (job 181, this session, the bytes of that moment)"
else
  bad "the deferred Stop did not upload a checkpoint=1 transcript: ${CK:-none}"
fi
[ -s "$HOME/.sidebutton/last-checkpoint" ] && ok "…and stamps the checkpoint window (the next tool call after the wait does not repeat it)" \
  || bad "the deferred checkpoint did not stamp last-checkpoint"
[ -f "$HOME/workspace/artifacts/review-evidence.png" ] && ok "…and the evidence file under artifacts/ is still on disk for the session to publish" \
  || bad "the deferred Stop drained (and deleted) artifacts/"
grep -qF 'paused, not finished — background work in flight (subagent a04a903e0cb039115): no session-stopped sentinel' "$LOG" \
  && ok "…and logs why the session is not marked stopped" || bad "no 'paused, not finished' log line"
# The fork returns; the session posts its verdict and ends the turn with the footer.
VERDICT=$'Code review done: 7 findings, all fixed and pushed.\n===SB_RESULT=== PASS'
fire "$(input Stop "$SID" '[]' '[]' "$VERDICT")"
expect_completed "run-3012 shape, 18:28 Stop (fork returned)" "$SID" "$VERDICT"
[ "$(artifacts)" = "review-evidence.png" ] && [ ! -e "$HOME/workspace/artifacts/review-evidence.png" ] \
  && ok "…and drains artifacts/ then (uploaded once, cleared on the 2xx)" || bad "the completing Stop did not drain artifacts/: '$(artifacts)'"
[ "$(sc_msg)" != "PREVIOUS-TURN-TEXT" ] \
  && ok "output_message comes from stdin last_assistant_message, not the transcript's stale closing text (QA F2)" \
  || bad "output_message is still the previous turn's text"

# ── 3. a notification already queued when the turn ends (QA F4a) ─────────────────────────────────────
SID="3c1d8e2f-7a9b-4c6d-8e0f-181f4a000001"
job_context "$SID"; new_transcript "$SID"; : > "$LOG"
queue_op "$SID" enqueue "$(notif a0c763fde92eeeff9)"
fire "$(input Stop "$SID" '[]' '[]' 'FINISHED')" 1
expect_deferred "background_tasks [] but a task-notification enqueued after the last tool call" "$SID" "queued a0c763fde92eeeff9"
queue_op "$SID" dequeue
fire "$(input Stop "$SID" '[]' '[]' 'FINISHED')"
expect_completed "…the Stop after its turn (enqueue, then dequeue)" "$SID" "FINISHED"
queue_op "$SID" enqueue "$(notif b9y3kq2vw)"
queue_op "$SID" remove "$(notif b9y3kq2vw)" absorbed_mid_turn
fire "$(input Stop "$SID" '[]' '[]' 'DONE')"
expect_completed "a notification absorbed mid-turn (enqueue, then remove)" "$SID" "DONE"
queue_op "$SID" enqueue "please also run the linters"
fire "$(input Stop "$SID" '[]' '[]' 'DONE')" 1
expect_deferred "an operator prompt queued while the turn ran" "$SID" "queued prompt"
tool_call "$SID"
fire "$(input Stop "$SID" '[]' '[]' 'DONE')"
expect_completed "a STALE enqueue (a later tool call came after it: a killed process's leftover)" "$SID" "DONE"

# ── 4. what holds a job, what does not ──────────────────────────────────────────────────────────────
SID="5a6b7c8d-9e0f-4a1b-8c2d-181000000004"
job_context "$SID"; new_transcript "$SID"
held() {  # $1 label  $2 background_tasks  $3 session_crons  $4 expected pending text
  : > "$LOG"; fire "$(input Stop "$SID" "$2" "$3" 'WAITING')" 1; expect_deferred "$1" "$SID" "$4"
}
free() {  # $1 label  $2 background_tasks  $3 session_crons
  fire "$(input Stop "$SID" "$2" "$3" 'DONE')"; expect_completed "$1" "$SID" "DONE"
}
held "a background shell (run_in_background)" '[{"id":"b8a0288qj","type":"shell","status":"running","command":"sleep 240"}]' '[]' "shell b8a0288qj"
free "…the shell returned" '[]' '[]'
held "an async Agent" '[{"id":"a4cdb3e8d5bb8477a","type":"subagent","status":"running","agent_type":"general-purpose"}]' '[]' "subagent a4cdb3e8d5bb8477a"
held "a pending (not yet started) task" '[{"id":"a1","type":"subagent","status":"pending"}]' '[]' "subagent a1"
held "a monitor" '[{"id":"m7","type":"monitor","status":"running","server":"ci","tool":"watch"}]' '[]' "monitor m7"
held "a workflow" '[{"id":"w1","type":"workflow","status":"running","name":"review"}]' '[]' "workflow w1"
held "a ScheduleWakeup (one-shot cron)" '[]' '[{"id":"8498e328","schedule":"21 20 29 09 *","recurring":false,"prompt":"wake"}]' "cron 8498e328"
free "a RECURRING cron alone (it never drains)" '[]' '[{"id":"c9","schedule":"*/5 * * * *","recurring":true,"prompt":"poll"}]'
free "the ambient kinds alone (dream, auto-mode scan: they never run a turn)" \
  '[{"id":"d1","type":"dream","status":"running"},{"id":"s1","type":"auto-mode scan","status":"running"}]' '[]'
free "an unknown kind (treated as the old behaviour, never a stranded job)" '[{"id":"x1","type":"hologram","status":"running"}]' '[]'
free "a task listed as finished" '[{"id":"b1","type":"shell","status":"completed"}]' '[]'
free "malformed fields (background_tasks a string, session_crons an object)" '"soon"' '{"id":"c1"}'
: > "$LOG"
fire "$(input Stop "$SID" - - 'DONE')"
expect_completed "a CLI that sends neither field (before 2.1.28x): every Stop completes, as it always did" "$SID" "DONE"
fire "$(input Stop "$SID" - - '')"
[ "$(sc_msg)" = "PREVIOUS-TURN-TEXT" ] && ok "…and with no last_assistant_message the transcript's last text is still the fallback" \
  || bad "the transcript fallback for output_message is gone: '$(sc_msg)'"
queue_op "$SID" enqueue "$(notif a0ld0c11e0000000)"
fire "$(input Stop "$SID" - - 'DONE')"
expect_completed "…even with an entry queued: the queue reading is only trusted beside the stdin fields it was verified with" "$SID" "DONE"
queue_op "$SID" dequeue

# An old runtime's job context names no session: the hook still reports (keyed by job_id/step_index) and still
# defers — but the checkpoint lane is strictly the job session's, so no upload.
printf '{"job_id":181,"step_index":0}\n' > "$HOME/.sidebutton/job-context.json"; : > "$LOG"
fire "$(input Stop "$SID" "$FORK" '[]' 'WAITING')"
expect_deferred "a job context with no session id (old runtime)" "$SID" "subagent a04a903e0cb039115"
[ -z "$(transcripts)" ] && ok "…and no checkpoint upload: that lane is strictly the job session's (as in sb-checkpoint-transcript.sh)" \
  || bad "a job context naming no session got a checkpoint upload: $(transcripts)"
fire "$(input Stop "$SID" '[]' '[]' 'DONE')"
expect_completed "…and the Stop after the work returned completes it" "$SID" "DONE"
job_context "$SID"

# ── 5. SubagentStop, non-job sessions, the checkpoint switch ────────────────────────────────────────
fire "$(input SubagentStop "$SID" "$FORK" '[]' 'sub done')"
[ "$RC" = 0 ] && [ "$(usage_final)" = false ] && [ "$(nposts)" = 1 ] && ! sentinel "$SID" && [ ! -e "$(marker "$SID")" ] \
  && ok "SubagentStop with work in flight: usage final=false only, as before (no marker, no sentinel)" \
  || bad "SubagentStop changed: rc=$RC final=$(usage_final) posts=$(nposts)"
OTHER="7e7e7e7e-0000-4000-8000-000000000181"
new_transcript "$OTHER"; : > "$LOG"
fire "$(input Stop "$OTHER" "$FORK" '[]' 'WAITING')"
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && ! sentinel "$OTHER" && [ ! -e "$(marker "$OTHER")" ] \
  && grep -q "session $OTHER != job session $SID — skipping portal posts" "$LOG" \
  && ok "a non-job session waiting on work: zero POSTs, no checkpoint, and it is not marked stopped while it waits" \
  || bad "a non-job session with pending work: rc=$RC posts=$(nposts)"
fire "$(input Stop "$OTHER" '[]' '[]' 'DONE')"
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && sentinel "$OTHER" \
  && ok "…and once it is done: still zero POSTs, and the sentinel is written ahead of the gate, as before" \
  || bad "a finished non-job session: rc=$RC posts=$(nposts) sentinel=$(sentinel "$OTHER" && echo yes || echo no)"
agent_env 'SB_CHECKPOINT_INTERVAL_SEC=0'; : > "$LOG"
fire "$(input Stop "$SID" "$FORK" '[]' 'WAITING')"
expect_deferred "SB_CHECKPOINT_INTERVAL_SEC=0" "$SID" "subagent a04a903e0cb039115"
[ -z "$(transcripts)" ] && ok "…and with the checkpoint switch off the deferred Stop uploads no transcript at all" \
  || bad "the deferred Stop ignored SB_CHECKPOINT_INTERVAL_SEC=0: $(transcripts)"
agent_env

# ── 6. AC5: the whole hook on a 3 MB transcript ─────────────────────────────────────────────────────
SID="0f0f0f0f-3333-4000-8000-00000000ac05"
job_context "$SID"; new_transcript "$SID"
PAD="$(head -c 1200 /dev/zero | tr '\0' 'x')"
jq -nc --arg s "$SID" --arg pad "$PAD" 'range(0; 1300) as $i |
  {type:"assistant", sessionId:$s, message:{model:"claude-opus-5-5", usage:{input_tokens:1, output_tokens:1},
    content:[{type:"tool_use", id:"toolu_\($i)", name:"Bash", input:{command:$pad}}]}},
  {type:"user", sessionId:$s, message:{role:"user", content:[{type:"tool_result", tool_use_id:"toolu_\($i)", content:$pad}]}}' \
  >> "$(tr_path "$SID")"
queue_op "$SID" enqueue "$(notif a7e3b62bf106bfced)"
SIZE="$(wc -c < "$(tr_path "$SID")" | tr -d ' ')"
[ "$SIZE" -ge 3000000 ] && ok "generated a ${SIZE}-byte transcript" || bad "the generated transcript is only ${SIZE} bytes"
t0="$(date +%s%3N)"; fire "$(input Stop "$SID" '[]' '[]' 'FINISHED')" 1; t1="$(date +%s%3N)"
expect_deferred "3 MB transcript with a queued notification" "$SID" "queued a7e3b62bf106bfced"
[ $((t1 - t0)) -lt 5000 ] && ok "AC5: the deferring hook ran in $((t1 - t0)) ms on ${SIZE} bytes (< 5 s, the checkpoint wait included)" \
  || bad "AC5: the deferring hook took $((t1 - t0)) ms"
queue_op "$SID" dequeue
t0="$(date +%s%3N)"; fire "$(input Stop "$SID" '[]' '[]' 'FINISHED')"; t1="$(date +%s%3N)"
expect_completed "3 MB transcript, the completing Stop" "$SID" "FINISHED"
[ $((t1 - t0)) -lt 5000 ] && ok "AC5: the completing hook ran in $((t1 - t0)) ms on ${SIZE} bytes (< 5 s, the final upload included)" \
  || bad "AC5: the completing hook took $((t1 - t0)) ms"

finish
