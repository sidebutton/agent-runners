#!/usr/bin/env bash
# base/tests/test-14-artifact-clear.sh — regression guard for the SCRUM-1604 cross-job
# artifact mis-attribution fix in 14-claude-stop-hook.sh.
#
# The final Stop globs <workspace>/artifacts/ and POSTs each file to /api/jobs/artifacts
# keyed on the CURRENT job's job_id/step_index/session_id. On a persistent-workspace VM
# artifacts/ was never cleared between jobs, so job N+1's Stop re-globbed and re-POSTed
# job N's leftover deliverables under job N+1's ids — job N's evidence attached to a
# DIFFERENT ticket. Server upsert on UNIQUE(job_id, step_index, filename) does not protect:
# a distinct job_id per job means job N's leftover inserts a fresh valid row under job N+1.
#
# The fix clears each file only on a 2xx POST (leaving non-2xx / curl-fail on disk for the
# next Stop's retry). This test extracts the real upload loop from the HOOKEOF heredoc,
# mocks curl (records every job_id->filename POSTed, returns a controllable HTTP code), and
# runs two consecutive jobs sharing one artifacts/ to prove:
#   - job 2 uploads ONLY its own file (job 1's 2xx files are gone → no cross-job leak),
#   - a failed (5xx) upload survives on disk and is retried on the next Stop,
#   - the ≤50 files / ≤25 MB caps are preserved.
#
# Pure bash (+ the same coreutils the hook uses: find/wc/basename/sed). No network — curl
# is a shell function that shadows the binary. Run: bash base/tests/test-14-artifact-clear.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 0. the installer must stay syntactically valid + carry the fix + keep the caps ──────
bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"
grep -qF 'case "$AR_CODE" in 2*) rm -f "$f"' "$HOOK" \
  && ok "upload loop carries the clear-on-2xx fix (SCRUM-1604)" \
  || bad "the clear-on-2xx fix is missing from the artifact upload loop"
grep -qF 'ART_MAX=50' "$HOOK" && grep -qF 'ART_MAX_BYTES=26214400' "$HOOK" \
  && ok "≤50 files / ≤25 MB caps preserved" \
  || bad "the ART_MAX / ART_MAX_BYTES caps were dropped"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the real upload loop (ART_N=0 … the summary log) from the HOOKEOF heredoc so we
# can drive it directly, without firing the whole Stop hook (which blocks on stdin, resolves
# a live workspace, and posts to the portal). Content anchors survive line-number drift.
awk '/ART_N=0/{p=1} p{print} /log "artifacts: posted/{exit}' "$HOOK" > "$TMP/upload.sh"
grep -q 'while IFS= read -r -d' "$TMP/upload.sh" \
  && ok "extracted the artifact upload loop from the hook heredoc" \
  || bad "could not extract the upload loop from the hook"

# curl mock: records "<job_id>\t<filename>" for every POST and echoes an HTTP code the loop
# captures as AR_CODE. Filenames matching $MOCK_FAIL_GLOB get a 500 (else 200), so we can
# drive per-file success/failure. It shadows the real curl for the sourced loop.
POSTLOG="$TMP/posted.tsv"
curl() {
  local a url=""
  for a in "$@"; do case "$a" in *"/api/jobs/artifacts?"*) url="$a" ;; esac; done
  local job file
  job="$(printf '%s' "$url"  | sed -n 's/.*[?&]job_id=\([^&]*\).*/\1/p')"
  file="$(printf '%s' "$url" | sed -n 's/.*[?&]filename=\([^&]*\).*/\1/p')"
  printf '%s\t%s\n' "$job" "$file" >> "$POSTLOG"
  case "$file" in ${MOCK_FAIL_GLOB:-__nomatch__}) printf '500' ;; *) printf '200' ;; esac
}
log() { :; }   # the loop calls log(); the real one lives elsewhere in the hook body

# env the extracted loop reads (set -u safe); ART_DIR/JOB_ID are (re)set per run below
export HOME="$TMP/home"; mkdir -p "$HOME"
PORTAL_URL="http://portal.test"; AGENT_TOKEN="tok"; AGENT_NAME="agent-x"
STEP_INDEX="0"; SESSION_ID="sid"; MOCK_FAIL_GLOB="__nomatch__"

run_stop() {  # run_stop <job_id> — one main-agent Stop for that job
  JOB_ID="$1"; SESSION_ID="sid-$1"
  . "$TMP/upload.sh"
}
posts_for() { grep -c "^$1"$'\t' "$POSTLOG" 2>/dev/null || echo 0; }  # count posts under a job_id

# ── 1. cross-job leak: two consecutive jobs share ONE persistent artifacts/ ─────────────
ART_DIR="$TMP/art"; mkdir -p "$ART_DIR"

# Job 1 (job_id=1001) produces two deliverables.
printf 'png-bytes'  > "$ART_DIR/job1-mockup.png"
printf 'coverage'   > "$ART_DIR/job1-coverage.txt"
: > "$POSTLOG"; run_stop 1001
[ "$(posts_for 1001)" = "2" ] && ok "job 1 POSTs its 2 files under job_id=1001" \
  || bad "job 1 posted $(posts_for 1001) files under 1001, expected 2"
{ [ ! -e "$ART_DIR/job1-mockup.png" ] && [ ! -e "$ART_DIR/job1-coverage.txt" ]; } \
  && ok "job 1's 2xx-uploaded files are cleared from disk" \
  || bad "job 1's files were NOT cleared after a successful upload"

# Job 2 (job_id=2002, a different ticket) produces one deliverable.
printf 'qa-bytes' > "$ART_DIR/job2-qa.png"
: > "$POSTLOG"; run_stop 2002
[ "$(wc -l < "$POSTLOG")" = "1" ] && ok "job 2's Stop POSTs exactly 1 file (only its own)" \
  || bad "job 2 POSTed $(wc -l < "$POSTLOG") files, expected 1 (leftover leak)"
grep -q $'^2002\tjob2-qa.png$' "$POSTLOG" \
  && ok "job 2 uploads job2-qa.png under job_id=2002" \
  || bad "job 2 did not upload its own file"
if grep -qE $'^2002\tjob1-' "$POSTLOG"; then
  bad "LEAK: job 2 re-POSTed job 1's leftover file under job_id=2002 (mis-attribution)"
else
  ok "no cross-job leak — job 1's evidence did NOT attach to job 2"
fi
[ -z "$(ls -A "$ART_DIR")" ] && ok "artifacts/ fully drained after both Stops (all 2xx)" \
  || bad "artifacts/ still holds files after both successful Stops: $(ls -A "$ART_DIR")"

# ── 2. failed upload survives for retry (clear-on-success only) ─────────────────────────
ART_DIR="$TMP/art2"; mkdir -p "$ART_DIR"
printf 'good' > "$ART_DIR/report-ok.txt"
printf 'boom' > "$ART_DIR/report-fail.txt"   # matched by the fail glob → 500
MOCK_FAIL_GLOB='*fail*'
: > "$POSTLOG"; run_stop 3003
[ ! -e "$ART_DIR/report-ok.txt" ] && ok "successful (2xx) file is removed" \
  || bad "a 2xx file was not removed"
[ -e "$ART_DIR/report-fail.txt" ] && ok "failed (500) file survives on disk for retry" \
  || bad "a failed upload was removed — it will never be retried"

# Next Stop (same job): the survivor is retried; the already-cleared file is not re-sent.
: > "$POSTLOG"; run_stop 3003
[ "$(wc -l < "$POSTLOG")" = "1" ] && grep -q $'\treport-fail.txt$' "$POSTLOG" \
  && ok "next Stop retries only the surviving failed file" \
  || bad "retry Stop POSTed '$(cat "$POSTLOG" | tr '\n' ';')', expected only report-fail.txt"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
