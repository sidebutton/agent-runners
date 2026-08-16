#!/usr/bin/env bash
# base/tests/test-14e-branch-attribution.sh — regression guard for SCRUM-1973: the git telemetry
# in 14-claude-stop-hook.sh must attribute commits/LOC to the work THIS job did, never to "everything
# new in the shared checkout since this session started".
#
# Prod (account 29 / Kurabu, 2026-08-13): runs 2355 (KD-6184) and 2356 (KD-2207) ran interleaved on
# one agent workspace and reported byte-identical aggregates — +1714 / -227 / 43 files / 5 commits —
# so KD-2207, a 6-line doc change, displayed 1,714 lines added (≈286× inflation). Both endpoints of
# the churn range were properties of the SHARED CHECKOUT (`rev-parse HEAD` for the end, a per-session
# pre-work snapshot for the start), so a neighbour's commits fell inside both jobs' ranges.
#
# The fix brackets every tool call (PreToolUse + PostToolUse) with each repo's branch+sha, so a sha
# that moves inside this session's own bracket is this job's work and one that moves in the gap
# between its tool calls is a neighbour's. Attribution by SIGHTINGS cannot draw that line, which is
# why several cases below look almost identical from the outside and must come out differently.
#
# The commit graph in scenario 1 is the prod scenario to the exact line counts: A = 4 commits
# +1708/-227 over 42 files, B = 1 commit +6 over 1 file, and the (buggy) union = 1714/227/43/5.
#
# Every case drives the REAL shipped code — the functions are extracted from the hook heredoc and the
# bracket log is produced by firing the REAL marker hook, so writer and reader can never drift.
#
# Isolated: fake HOME, throwaway repos, stubbed `gh` (no network, no real ~/.sidebutton).
# Needs bash + git + jq + awk. Run: bash base/tests/test-14e-branch-attribution.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
HOOKS_JSON="$BASE/assets/claude-hooks.json"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — SCRUM-1973 assertions need it"
  echo; echo "ALL PASS"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── the hook config must actually wire the PRE half, or the bracket is half-open ─────────────────
jq -e '.hooks.PreToolUse[] | select(.matcher==".*") | .hooks[]
       | select(.command | test("sb-mark-tool-use\\.sh"))' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json fires sb-mark-tool-use.sh on PreToolUse .* (the bracket's opening half)" \
  || bad "no PreToolUse .* entry for sb-mark-tool-use.sh — every tool call would be unbracketed"
jq -e '.hooks.PostToolUse[] | select(.matcher==".*") | .hooks[]
       | select(.command | test("sb-mark-tool-use\\.sh"))' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "claude-hooks.json still fires it on PostToolUse .* (the closing half)" \
  || bad "PostToolUse .* entry for sb-mark-tool-use.sh is missing"

# ── extract the real capture functions + the real marker hook ────────────────────────────────────
awk '/^normalize_repo_url\(\) \{/{p=1} p{print} /^capture_git_prs\(\) \{/{c=1} c&&/^\}/{exit}' "$HOOK" > "$TMP/funcs.sh"
grep -q '^job_branch_candidates() {' "$TMP/funcs.sh" \
  && ok "job_branch_candidates extracted with the capture helpers (declared before capture_git_prs)" \
  || bad "job_branch_candidates is missing or declared after capture_git_prs — capture would break at runtime"
grep -q '^branch_start_sha() {' "$TMP/funcs.sh" \
  && ok "branch_start_sha extracted with the capture helpers" \
  || bad "branch_start_sha is missing or declared after capture_git_prs"
grep -q '^mark_session_bracket() {' "$TMP/funcs.sh" \
  && ok "mark_session_bracket extracted with the capture helpers" \
  || bad "mark_session_bracket is missing or declared after capture_git_prs"
# The capture functions live inside a heredoc, so `bash -n` on the installer never parses them —
# an unbalanced quote in the embedded awk would only surface on a live agent. Parse them here.
bash -n "$TMP/funcs.sh" && ok "bash -n: the extracted capture functions (heredoc body really parses)" \
  || bad "the capture functions do not parse — the Stop hook would die on a live agent"

awk "/cat > .*sb-mark-tool-use.sh.*<<'TUEOF'/{f=1;next} /^TUEOF\$/{f=0} f" "$HOOK" > "$TMP/sb-mark-tool-use.sh"
bash -n "$TMP/sb-mark-tool-use.sh" && ok "bash -n: sb-mark-tool-use.sh" \
  || bad "bash -n failed on sb-mark-tool-use.sh"

awk "/cat > .*sb-session-start.sh.*<<'SESSIONEOF'/{f=1;next} /^SESSIONEOF\$/{f=0} f" "$HOOK" > "$TMP/sb-session-start.sh"
bash -n "$TMP/sb-session-start.sh" && ok "bash -n: sb-session-start.sh" \
  || bad "bash -n failed on sb-session-start.sh"

# ── sandbox: fake HOME + a stubbed gh that records the branch it was asked about ─────────────────
export HOME="$TMP/home"
mkdir -p "$HOME/.sidebutton" "$HOME/workspace" "$TMP/stub"
cat > "$TMP/stub/gh" <<'GHEOF'
#!/usr/bin/env bash
# records its argv, then answers per $GH_MODE: none (no PR) | pr (a PR with PR-WIDE churn)
printf '%s\n' "$*" >> "$GH_ARGS_LOG"
[ "${GH_MODE:-none}" = "pr" ] || exit 1
cat <<'JSON'
{"url":"https://github.com/kurabu/kurabu-app/pull/42","number":42,"state":"OPEN","mergedAt":null,
 "additions":9999,"deletions":8888,"changedFiles":777,"commits":[1,2,3,4,5,6]}
JSON
GHEOF
chmod +x "$TMP/stub/gh"
export PATH="$TMP/stub:$PATH"
export GH_ARGS_LOG="$TMP/gh-args.log"; : > "$GH_ARGS_LOG"
export GH_MODE=none

# Drive the REAL marker hook exactly as Claude Code does: PreToolUse fires, the tool runs, PostToolUse
# fires. `tool_call SID [cmd...]` is one tool call for that session; with no cmd it is a read-only
# call — the bracket still fires, which is precisely how a job proves it did nothing.
tool_call() {
  local sid="$1"; shift
  printf '{"session_id":"%s","hook_event_name":"PreToolUse"}'  "$sid" | bash "$TMP/sb-mark-tool-use.sh" 2>/dev/null
  [ $# -gt 0 ] && "$@" >/dev/null 2>&1
  printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$sid" | bash "$TMP/sb-mark-tool-use.sh" 2>/dev/null
  return 0
}

# The marker hook walks the agent's workspace ($HOME/workspace), so each scenario gets its OWN HOME
# rather than a second workspace dir — that keeps every scenario at the real on-box layout while
# still isolating them from each other (the bracket log and the session baselines live under $HOME too).
new_home() { export HOME="$TMP/$1"; mkdir -p "$HOME/.sidebutton" "$HOME/workspace"; }

# Open a session the way the box does: the REAL SessionStart hook writes both the HEAD baseline and
# the list of branches that already exist, which is what lets capture tell "I cut this branch" from
# "I switched to someone else's".
session_start() { printf '{"session_id":"%s"}' "$1" | bash "$TMP/sb-session-start.sh" 2>/dev/null; return 0; }

new_repo() {  # $1 = path, $2 = origin url  → a repo on main with one base commit + origin/HEAD
  git init -q -b main "$1"
  git -C "$1" config user.email agent@sidebutton.com; git -C "$1" config user.name "agent"
  git -C "$1" remote add origin "$2"
  printf 'seed\n' > "$1/seed.txt"
  git -C "$1" add -A >/dev/null; git -C "$1" commit -qm "base: initial import"
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse HEAD)"
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
mklines() { local pfx="$1" n="$2" i; for ((i=1;i<=n;i++)); do echo "$pfx line $i"; done; }
agg() { printf '%s' "$1" | jq -c '(.[0] // {}) | {lines_added,lines_deleted,files_changed,commits}' 2>/dev/null; }
len() { printf '%s' "$1" | jq 'length' 2>/dev/null; }

# =================================================================================================
# SCENARIO 1 — the prod shape: two interleaved jobs, one shared checkout
# =================================================================================================
new_home home1
H1="$HOME"
WS="$HOME/workspace"; REPO="$WS/kurabu"
new_repo "$REPO" https://github.com/kurabu/kurabu-app.git
S0=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/src" "$REPO/docs"
for i in $(seq -w 1 10); do mklines "OLD-e$i" 40 > "$REPO/src/e$i.txt"; done
mklines "doc" 12 > "$REPO/docs/importer.md"
git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -q --amend -qm "base: initial import"
S0=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" update-ref refs/remotes/origin/main "$S0"

SID_A="sess-A-2355"   # run 2355 / KD-6184 — the big feature
SID_B="sess-B-2356"   # run 2356 / KD-2207 — "Importer — update description", 6 doc lines
session_start "${SID_A}"
session_start "${SID_B}"

a_cut()    { git -C "$REPO" checkout -q -b feat/kd-6184; }
a_batch()  {  # $1 = batch number, adds 47-line files
  local c="$1" k
  for k in $(seq 1 16); do
    [ "$c" -eq 2 ] && [ "$k" -eq 16 ] && continue
    A_N=$((A_N+1)); mklines "NEW-f$A_N" 47 > "$REPO/src/f$A_N.txt"
  done
  git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -qm "feat(kd-6184): batch $c"
}
a_batch3() { mklines "NEW-f32" 43 > "$REPO/src/f32.txt"; git -C "$REPO" add -A >/dev/null
             git -C "$REPO" commit -qm "feat(kd-6184): batch 3"; }
a_batch4() {
  local d=(23 23 23 23 23 23 23 23 23 20) a=(21 21 21 21 21 21 21 21 21 19) idx=0 i
  for i in $(seq -w 1 10); do
    { mklines "NEW-e$i" "${a[$idx]}"; tail -n +$(( ${d[$idx]} + 1 )) "$REPO/src/e$i.txt"; } > "$REPO/src/e$i.tmp"
    mv "$REPO/src/e$i.tmp" "$REPO/src/e$i.txt"; idx=$((idx+1))
  done
  git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -qm "feat(kd-6184): batch 4"
}
A_N=0
tool_call "$SID_A" a_cut
tool_call "$SID_A" a_batch 1
tool_call "$SID_A" a_batch 2
tool_call "$SID_A" a_batch3
tool_call "$SID_A" a_batch4
A_TIP=$(git -C "$REPO" rev-parse HEAD)

# Job B branches off the SHARED checkout's current HEAD (= A's tip) — the shared-checkout trap —
# and makes its one small doc commit, both inside one tool call.
b_work() { git -C "$REPO" checkout -q -b fix/kd-2207
           mklines "doc-new" 6 >> "$REPO/docs/importer.md"
           git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -qm "fix(kd-2207): importer — update description"; }
tool_call "$SID_B"
tool_call "$SID_B" b_work
B_TIP=$(git -C "$REPO" rev-parse HEAD)
# ...and A is still alive while B owns HEAD: two of A's read-only tool calls now see B's branch.
tool_call "$SID_A"; tool_call "$SID_A"

# shellcheck source=/dev/null
. "$TMP/funcs.sh"

A_OUT="$(capture_git_prs "$WS" "$SID_A" 2>/dev/null)"
B_OUT="$(capture_git_prs "$WS" "$SID_B" 2>/dev/null)"
A_AGG="$(agg "$A_OUT")"; B_AGG="$(agg "$B_OUT")"

[ "$A_AGG" != "$B_AGG" ] \
  && ok "interleaved jobs no longer report identical aggregates (A=$A_AGG B=$B_AGG)" \
  || bad "cross-attribution persists: both jobs report $A_AGG"
[ "$A_AGG" = '{"lines_added":1708,"lines_deleted":227,"files_changed":42,"commits":4}' ] \
  && ok "job A (KD-6184) = its own branch's truth +1708/-227/42 files/4 commits" \
  || bad "job A aggregates wrong: $A_AGG (expected +1708/-227/42/4)"
[ "$B_AGG" = '{"lines_added":6,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "job B (KD-2207) = its own branch's truth +6/1 file/1 commit (was the prod +1714)" \
  || bad "job B aggregates wrong: $B_AGG (expected +6/-0/1/1)"

as="$(printf '%s' "$A_OUT" | jq -r '.[0].sha_start')"; ae="$(printf '%s' "$A_OUT" | jq -r '.[0].sha_end')"
bs="$(printf '%s' "$B_OUT" | jq -r '.[0].sha_start')"; be="$(printf '%s' "$B_OUT" | jq -r '.[0].sha_end')"
[ "$ae" = "$A_TIP" ] && [ "$be" = "$B_TIP" ] \
  && ok "sha_end is each job's OWN branch head, not the shared checkout's HEAD" \
  || bad "sha_end wrong: A='$ae' (want $A_TIP), B='$be' (want $B_TIP)"
[ "$as" = "$S0" ] && [ "$bs" = "$A_TIP" ] \
  && ok "sha_start is each job's own starting point (B starts at A's tip, not the shared baseline)" \
  || bad "sha_start wrong: A='$as' (want $S0), B='$bs' (want $A_TIP)"

# ── gh is asked about the JOB's branch, and PR-wide churn does not overwrite job churn ───────────
: > "$GH_ARGS_LOG"; export GH_MODE=pr
A3="$(capture_git_prs "$WS" "$SID_A" 2>/dev/null)"
grep -q 'pr view feat/kd-6184' "$GH_ARGS_LOG" \
  && ok "gh pr view is asked for the job's branch (not whatever is checked out)" \
  || bad "gh was called as: $(head -1 "$GH_ARGS_LOG") — expected 'pr view feat/kd-6184'"
[ "$(printf '%s' "$A3" | jq -r '.[0].pr_url')" = "https://github.com/kurabu/kurabu-app/pull/42" ] \
  && ok "PR identity still comes from gh (url/number/state kept)" \
  || bad "PR identity lost: $(printf '%s' "$A3" | jq -c '.[0]|{pr_url,pr_number,state}')"
[ "$(agg "$A3")" = "$A_AGG" ] \
  && ok "PR-wide churn does not overwrite this job's git-derived churn (follow-up-job inflation)" \
  || bad "PR churn overwrote job churn: $(agg "$A3"), expected $A_AGG"
export GH_MODE=none

# ── commits is two-dot (three-dot counted the neighbour's side too) ──────────────────────────────
[ "$(printf '%s' "$A_OUT" | jq -r '.[0].commits')" = "4" ] \
  && ok "commits counts only this job's commits (two-dot rev-list)" \
  || bad "commits over-counted: $(printf '%s' "$A_OUT" | jq -r '.[0].commits'), expected 4"

# =================================================================================================
# SCENARIO 2 — branch + commit inside ONE tool call (`git checkout -b x && git commit`)
# The single most common agent pattern. Nothing observed AFTER the tool call can supply a pre-commit
# anchor, so a design that only samples post-tool-call reports this job as having done nothing.
# =================================================================================================
new_home home2
WS2="$HOME/workspace"; R2="$WS2/proj"
new_repo "$R2" https://github.com/acme/proj.git
R2_S0=$(git -C "$R2" rev-parse HEAD)
SID_S="sess-solo"
session_start "${SID_S}"
s_cut_and_commit() { git -C "$R2" checkout -q -b feat/x
                     mklines "feat" 120 > "$R2/big.txt"
                     git -C "$R2" add -A >/dev/null; git -C "$R2" commit -qm "feat: x"; }
s_second()         { mklines "more" 3 >> "$R2/big.txt"
                     git -C "$R2" add -A >/dev/null; git -C "$R2" commit -qm "feat: x follow-on"; }
tool_call "$SID_S"                      # a read on main first
tool_call "$SID_S" s_cut_and_commit     # branch AND commit in one call
tool_call "$SID_S"
S_OUT="$(capture_git_prs "$WS2" "$SID_S" 2>/dev/null)"
[ "$(agg "$S_OUT")" = '{"lines_added":120,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "branch+commit in ONE tool call is attributed (+120/1 file/1 commit), not dropped" \
  || bad "solo job's work lost or wrong: $(agg "$S_OUT") — expected +120/1/1"
[ "$(printf '%s' "$S_OUT" | jq -r '.[0].sha_start')" = "$R2_S0" ] \
  && ok "its sha_start is the pre-tool-call sha, the only anchor that exists for this shape" \
  || bad "sha_start '$(printf '%s' "$S_OUT" | jq -r '.[0].sha_start')' != '$R2_S0'"

tool_call "$SID_S" s_second
S_OUT2="$(capture_git_prs "$WS2" "$SID_S" 2>/dev/null)"
[ "$(agg "$S_OUT2")" = '{"lines_added":123,"lines_deleted":0,"files_changed":1,"commits":2}' ] \
  && ok "a later commit adds to the same range (+123/2 commits), first commit not lost" \
  || bad "multi-commit session wrong: $(agg "$S_OUT2") — expected +123/1 file/2 commits"

# =================================================================================================
# SCENARIO 3 — read-only job while a NEIGHBOUR commits in the gaps between its tool calls
# The neighbour's commits land between this job's post and its next pre, so they are not its work.
# By sightings this is indistinguishable from the SE job that owns the branch.
# =================================================================================================
new_home home3
WS3="$HOME/workspace"; R3="$WS3/proj"
new_repo "$R3" https://github.com/acme/proj3.git
se_cut()    { git -C "$R3" checkout -q -b feat/se; mklines "se" 50 > "$R3/se.txt"
              git -C "$R3" add -A >/dev/null; git -C "$R3" commit -qm "se: first"; }
se_commit2(){ mklines "se2" 900 > "$R3/se2.txt"; git -C "$R3" add -A >/dev/null
              git -C "$R3" commit -qm "se: second"; }
SID_SE="sess-se"; SID_QA="sess-qa"
session_start "${SID_SE}"
tool_call "$SID_SE" se_cut
session_start "${SID_QA}"
tool_call "$SID_QA"                # QA reads
se_commit2                         # neighbour commits IN THE GAP between QA's tool calls
tool_call "$SID_QA"; tool_call "$SID_QA"
QA_OUT="$(capture_git_prs "$WS3" "$SID_QA" 2>/dev/null)"
[ "$(len "$QA_OUT")" = "0" ] \
  && ok "read-only job reports nothing even though the branch moved during its session" \
  || bad "read-only job inherited the neighbour's commits: $(agg "$QA_OUT")"

# =================================================================================================
# SCENARIO 4 — two interleaved SE jobs: the victim spends most of its session on the OTHER's branch
# B's own branch has far fewer sightings than A's, so a most-sighted rule hands B its neighbour's diff.
# =================================================================================================
new_home home4
WS4="$HOME/workspace"; R4="$WS4/proj"
new_repo "$R4" https://github.com/acme/proj4.git
SID_A4="sess-a4"; SID_B4="sess-b4"
a4_cut()  { git -C "$R4" checkout -q -b feat/a4; mklines "a" 1000 > "$R4/a.txt"
            git -C "$R4" add -A >/dev/null; git -C "$R4" commit -qm "a: one"; }
a4_more() { mklines "a2" 700 > "$R4/a2.txt"; git -C "$R4" add -A >/dev/null
            git -C "$R4" commit -qm "a: two"; }
b4_work() { git -C "$R4" checkout -q -b fix/b4; mklines "b" 5 > "$R4/b.txt"
            git -C "$R4" add -A >/dev/null; git -C "$R4" commit -qm "b: small"; }
session_start "${SID_A4}"
tool_call "$SID_A4" a4_cut
session_start "${SID_B4}"
for i in 1 2 3 4 5 6 7 8 9 10; do tool_call "$SID_B4"; done   # B reads on A's branch
tool_call "$SID_A4" a4_more                                   # A commits +700 in B's gap
for i in 1 2 3; do tool_call "$SID_B4"; done
tool_call "$SID_B4" b4_work                                   # B finally does its own small work
B4_OUT="$(capture_git_prs "$WS4" "$SID_B4" 2>/dev/null)"
A4_OUT="$(capture_git_prs "$WS4" "$SID_A4" 2>/dev/null)"
[ "$(agg "$B4_OUT")" = '{"lines_added":5,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "the out-sighted job reports its OWN small change (+5/1/1), not its neighbour's +700" \
  || bad "job B4 reported $(agg "$B4_OUT") — expected +5/1 file/1 commit"
[ "$(agg "$A4_OUT")" = '{"lines_added":1700,"lines_deleted":0,"files_changed":2,"commits":2}' ] \
  && ok "and its neighbour still reports its own full +1700/2 files/2 commits" \
  || bad "job A4 reported $(agg "$A4_OUT") — expected +1700/2 files/2 commits"

# =================================================================================================
# SCENARIO 5 — a job legitimately working on the DEFAULT branch, with one incidental sighting of a
# neighbour's branch. A "non-default branch ranks first" rule lets that single sighting hijack it.
# =================================================================================================
new_home home5
WS5="$HOME/workspace"; R5="$WS5/proj"
new_repo "$R5" https://github.com/acme/proj5.git
SID_X="sess-x"
session_start "${SID_X}"
x_commit() { mklines "x$1" 20 > "$R5/x$1.txt"; git -C "$R5" add -A >/dev/null
             git -C "$R5" commit -qm "x: $1"; }
tool_call "$SID_X" x_commit 1
tool_call "$SID_X" x_commit 2
tool_call "$SID_X" x_commit 3
git -C "$R5" checkout -q -b feat/neighbour     # a neighbour cuts its branch...
tool_call "$SID_X"                             # ...and one of X's reads happens to see it
n5_commit() { mklines "n" 2000 > "$R5/n.txt"; git -C "$R5" add -A >/dev/null
              git -C "$R5" commit -qm "n: big"; }
n5_commit                                      # neighbour commits +2000 in X's gap
X_OUT="$(capture_git_prs "$WS5" "$SID_X" 2>/dev/null)"
[ "$(agg "$X_OUT")" = '{"lines_added":60,"lines_deleted":0,"files_changed":3,"commits":3}' ] \
  && ok "a default-branch job keeps its own +60/3 files/3 commits despite the neighbour sighting" \
  || bad "default-branch job reported $(agg "$X_OUT") — expected +60/3 files/3 commits"

# =================================================================================================
# SCENARIO 6 — follow-up job resuming an EXISTING branch reports only its own turn
# =================================================================================================
export HOME="$H1"
SID_F="sess-followup"
git -C "$REPO" checkout -q feat/kd-6184
F_BASE="$(git -C "$REPO" rev-parse HEAD)"
session_start "${SID_F}"
f_work() { printf 'follow-up\n' >> "$REPO/docs/importer.md"; git -C "$REPO" add -A >/dev/null
           git -C "$REPO" commit -qm "fix(kd-6184): follow-up"; }
tool_call "$SID_F"
tool_call "$SID_F" f_work
F_OUT="$(capture_git_prs "$WS" "$SID_F" 2>/dev/null)"
[ "$(agg "$F_OUT")" = '{"lines_added":1,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "follow-up job on an existing branch reports only its own commit (+1/1 file/1 commit)" \
  || bad "follow-up job re-reported the branch's history: $(agg "$F_OUT")"
[ "$(printf '%s' "$F_OUT" | jq -r '.[0].sha_start')" = "$F_BASE" ] \
  && ok "follow-up sha_start is its own turn's start, not the branch's creation point" \
  || bad "follow-up sha_start '$(printf '%s' "$F_OUT" | jq -r '.[0].sha_start')' != '$F_BASE'"

# =================================================================================================
# SCENARIO 7 — non-regression: no data must never be read as "did nothing"
# =================================================================================================
D_OUT="$(capture_git_prs "$WS" "sess-nolog" 2>/dev/null)"
[ "$(len "$D_OUT")" = "1" ] \
  && ok "no bracket log at all (old box) => legacy fallback, still captured" \
  || bad "expected 1 element without a bracket log, got $(len "$D_OUT")"

# a log that exists but holds no complete pair for this repo (detached HEAD is never recorded)
OWS="$HOME/other-ws"; OREPO="$OWS/detached"
mkdir -p "$OWS"; new_repo "$OREPO" https://github.com/acme/detached.git
printf 'a\nb\n' > "$OREPO/seed.txt"; git -C "$OREPO" add -A >/dev/null; git -C "$OREPO" commit -qm change
O_OUT="$(capture_git_prs "$OWS" "$SID_A" 2>/dev/null)"
[ "$(len "$O_OUT")" = "1" ] \
  && ok "log with no pair for a repo => legacy fallback, not a silent drop" \
  || bad "a repo absent from the bracket log was dropped (got $(len "$O_OUT") elements)"

# =================================================================================================
# SCENARIO 8 — a SessionStart that loses the job-context race still writes its baseline
# =================================================================================================
printf '{"session_id":"%s","entry_path":"%s"}\n' "$SID_A" "$WS" > "$HOME/.sidebutton/job-context.json"
rm -f "$HOME/.sidebutton/session-heads-sess-E-raced.json"
printf '{"session_id":"sess-E-raced"}' | bash "$TMP/sb-session-start.sh" 2>/dev/null
[ -f "$HOME/.sidebutton/session-heads-sess-E-raced.json" ] \
  && ok "a SessionStart that loses the job-context race still writes its own baseline" \
  || bad "no baseline written for the raced session — capture falls back to claiming the whole branch"
[ "$(jq -r --arg k "$REPO" '.[$k] // ""' "$HOME/.sidebutton/session-heads-sess-E-raced.json")" != "" ] \
  && ok "the raced baseline carries the workspace repo's HEAD" \
  || bad "raced baseline is empty"

# =================================================================================================
# SCENARIO 9 — a checkout INSIDE a tool call must not fabricate an advance of the branch it lands on
# The pre line is on the old branch and the post line on the new one; pairing those across branches
# anchors the destination branch at the source branch's sha and claims everything in between.
# =================================================================================================
new_home home9
WS9="$HOME/workspace"; R9="$WS9/proj"
new_repo "$R9" https://github.com/acme/proj9.git
M0="$(git -C "$R9" rev-parse HEAD)"
git -C "$R9" checkout -q -b feat/se
mklines "se1" 700 > "$R9/se1.txt"; git -C "$R9" add -A >/dev/null; git -C "$R9" commit -qm "se: 1"
mklines "se2" 800 > "$R9/se2.txt"; git -C "$R9" add -A >/dev/null; git -C "$R9" commit -qm "se: 2"
git -C "$R9" checkout -q main
SID_Q9="sess-qa9"
session_start "${SID_Q9}"
q9_checkout() { git -C "$R9" checkout -q feat/se; }
tool_call "$SID_Q9"                    # a read on main
tool_call "$SID_Q9" q9_checkout        # one tool call that only switches branch
tool_call "$SID_Q9"
Q9_OUT="$(capture_git_prs "$WS9" "$SID_Q9" 2>/dev/null)"
[ "$(len "$Q9_OUT")" = "0" ] \
  && ok "checking out a neighbour's branch claims nothing (a checkout is not an advance)" \
  || bad "a bare checkout claimed the branch: $(agg "$Q9_OUT")"

# 9b. and the follow-up job that checks out an existing branch then commits reports only its commit
SID_F9="sess-followup9"
git -C "$R9" checkout -q main
session_start "${SID_F9}"
f9_commit() { mklines "mine" 3 >> "$R9/se1.txt"; git -C "$R9" add -A >/dev/null
              git -C "$R9" commit -qm "follow-up"; }
SE_TIP="$(git -C "$R9" rev-parse refs/heads/feat/se)"
tool_call "$SID_F9" q9_checkout        # call 1: switch to the existing branch
tool_call "$SID_F9" f9_commit          # call 2: its own small commit
F9_OUT="$(capture_git_prs "$WS9" "$SID_F9" 2>/dev/null)"
[ "$(agg "$F9_OUT")" = '{"lines_added":3,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "follow-up job that checks out then commits reports +3, not the branch's prior +1500" \
  || bad "follow-up over-reported: $(agg "$F9_OUT") — expected +3/1 file/1 commit"
[ "$(printf '%s' "$F9_OUT" | jq -r '.[0].sha_start')" = "$SE_TIP" ] \
  && ok "its sha_start is the branch tip it found, not the sha it came from" \
  || bad "sha_start '$(printf '%s' "$F9_OUT" | jq -r '.[0].sha_start')' != '$SE_TIP'"

# =================================================================================================
# SCENARIO 10 — parallel tool calls: Claude Code batches them, so brackets interleave
# pre A, pre B, post B, post A — the LAST post of a batch must still find its anchor.
# =================================================================================================
new_home home10
WS10="$HOME/workspace"; R10="$WS10/proj"
new_repo "$R10" https://github.com/acme/proj10.git
git -C "$R10" checkout -q -b feat/y
SID_P="sess-parallel"
session_start "${SID_P}"
mark() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$SID_P" "$1" | bash "$TMP/sb-mark-tool-use.sh" 2>/dev/null; }
mark PreToolUse                         # call A starts
mark PreToolUse                         # call B starts (batched alongside A)
mark PostToolUse                        # call B finishes first, changed nothing
mklines "work" 400 > "$R10/a.txt"; git -C "$R10" add -A >/dev/null
git -C "$R10" commit -qm "a: work"      # ...then A's command commits
mark PostToolUse                        # call A finishes
P_OUT="$(capture_git_prs "$WS10" "$SID_P" 2>/dev/null)"
[ "$(agg "$P_OUT")" = '{"lines_added":400,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "interleaved parallel brackets still attribute the work (+400/1 file/1 commit)" \
  || bad "parallel tool calls lost the job's work: $(agg "$P_OUT") — expected +400/1/1"

# =================================================================================================
# SCENARIO 11 — a job whose ONLY commit is the Stop-time autosave, made after the last PostToolUse
# =================================================================================================
new_home home11
WS11="$HOME/workspace"; R11="$WS11/proj"
new_repo "$R11" https://github.com/acme/proj11.git
SID_AS="sess-autosave"
session_start "${SID_AS}"
edit_only() { mklines "edit" 5 > "$R11/edited.txt"; }
tool_call "$SID_AS" edit_only           # edits the worktree, never runs git
tool_call "$SID_AS"
# the Stop hook brackets its autosave: open, commit, close
mark_session_bracket "$WS11" "$SID_AS" spre
git -C "$R11" add -A >/dev/null; git -C "$R11" commit -qm "chore: autosave"
mark_session_bracket "$WS11" "$SID_AS" spost
AS_OUT="$(capture_git_prs "$WS11" "$SID_AS" 2>/dev/null)"
[ "$(agg "$AS_OUT")" = '{"lines_added":5,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "a Stop-time autosave commit is still this job's work (+5/1 file/1 commit)" \
  || bad "autosave-only session reported $(agg "$AS_OUT") — expected +5/1 file/1 commit"
# The bracket must be TIGHT around the autosave: open before it, close after it, capture last.
open_ln=$(grep -n 'mark_session_bracket "$ENTRY_PATH" "$SESSION_ID" spre'  "$HOOK" | head -1 | cut -d: -f1)
autos_ln=$(grep -n 'sb-app-autosave.sh" turn' "$HOOK" | head -1 | cut -d: -f1)
close_ln=$(grep -n 'mark_session_bracket "$ENTRY_PATH" "$SESSION_ID" spost' "$HOOK" | head -1 | cut -d: -f1)
caps_ln=$(grep -n 'PRS_JSON=$(capture_git_prs' "$HOOK" | head -1 | cut -d: -f1)
[ -n "$open_ln" ] && [ -n "$autos_ln" ] && [ "$open_ln" -lt "$autos_ln" ] \
  && [ "$autos_ln" -lt "$close_ln" ] && [ "$close_ln" -lt "$caps_ln" ] \
  && ok "ordering is open bracket -> autosave -> close bracket -> capture" \
  || bad "bad ordering: open=$open_ln autosave=$autos_ln close=$close_ln capture=$caps_ln"

# =================================================================================================
# SCENARIO 12 — no data must stay "no data" even when git-written lines are present
# The marker reads refs with builtins, so it records an empty sha when it cannot read one (packed
# refs, or a worktree where .git is a file). The git-written start/session lines always carry a real
# sha — counting those as observations would turn the safe legacy fallback into a false zero.
# =================================================================================================
new_home home12
WS12="$HOME/workspace"; R12="$WS12/proj"
new_repo "$R12" https://github.com/acme/proj12.git
SID_PK="sess-packed"
session_start "${SID_PK}"
git -C "$R12" pack-refs --all                 # what `git gc --auto` does: no loose refs left
pk_work() { git -C "$R12" checkout -q -b feat/p; mklines "p" 250 > "$R12/p.txt"
            git -C "$R12" add -A >/dev/null; git -C "$R12" commit -qm "p: work"; }
tool_call "$SID_PK"
tool_call "$SID_PK" pk_work
mark_session_bracket "$WS12" "$SID_PK" spre
mark_session_bracket "$WS12" "$SID_PK" spost
PK_OUT="$(capture_git_prs "$WS12" "$SID_PK" 2>/dev/null)"
[ "$(len "$PK_OUT")" = "1" ] && [ "$(printf '%s' "$PK_OUT" | jq -r '.[0].lines_added')" = "250" ] \
  && ok "packed refs (marker blind) => legacy fallback still reports +250, not a false zero" \
  || bad "packed-ref repo reported $(agg "$PK_OUT") / len=$(len "$PK_OUT") — expected a legacy +250"

# 12b. same shape for a worktree, where .git is a FILE the builtins-only marker cannot follow
WT="$WS12/wt"
git -C "$R12" worktree add -q -b feat/wt "$WT" 2>/dev/null
SID_WT="sess-worktree"
session_start "${SID_WT}"
wt_work() { mklines "w" 450 > "$WT/w.txt"; git -C "$WT" add -A >/dev/null
            git -C "$WT" commit -qm "w: work"; }
tool_call "$SID_WT" wt_work
WT_OUT="$(capture_git_prs "$WT" "$SID_WT" 2>/dev/null)"
[ "$(printf '%s' "$WT_OUT" | jq -r '(.[0].lines_added) // "none"')" = "450" ] \
  && ok "worktree (.git is a file, marker blind) => legacy fallback still reports +450" \
  || bad "worktree reported $(agg "$WT_OUT") — expected a legacy +450"

# =================================================================================================
# SCENARIO 13 — the stretch between the last tool call and Stop belongs to nobody
# Final-message generation happens there. Treating it as a tool call would hand this job whatever a
# neighbour committed while the model was writing its answer.
# =================================================================================================
new_home home13
WS13="$HOME/workspace"; R13="$WS13/proj"
new_repo "$R13" https://github.com/acme/proj13.git
git -C "$R13" checkout -q -b feat/n13         # the checkout sits on a neighbour's branch
SID_G="sess-finalgap"
session_start "${SID_G}"
tool_call "$SID_G"; tool_call "$SID_G"        # this job reads, changes nothing
mklines "n" 700 > "$R13/n.txt"; git -C "$R13" add -A >/dev/null
git -C "$R13" commit -qm "neighbour: after my last tool call"
mark_session_bracket "$WS13" "$SID_G" spre    # ...then Stop runs: open, autosave (nothing), close
mark_session_bracket "$WS13" "$SID_G" spost
G_OUT="$(capture_git_prs "$WS13" "$SID_G" 2>/dev/null)"
[ "$(len "$G_OUT")" = "0" ] \
  && ok "a neighbour's commit in the last-tool-call-to-Stop gap is not this job's" \
  || bad "the final gap was attributed to this job: $(agg "$G_OUT")"

# =================================================================================================
# SCENARIO 14 — `git checkout <existing-branch> && git commit` in ONE tool call
# The post lands on a branch with no pre of its own, and the branch already existed. Anchoring it at
# the sha it had when THIS session opened keeps the job's own commit without reaching back into the
# previous job's work on the same branch.
# =================================================================================================
new_home home14
WS14="$HOME/workspace"; R14="$WS14/proj"
new_repo "$R14" https://github.com/acme/proj14.git
git -C "$R14" checkout -q -b feat/e
mklines "prev" 1200 > "$R14/prev.txt"; git -C "$R14" add -A >/dev/null
git -C "$R14" commit -qm "previous job: big work"     # an EARLIER job's work on this branch
git -C "$R14" checkout -q main
E0="$(git -C "$R14" rev-parse refs/heads/feat/e)"
SID_E="sess-existing"
session_start "${SID_E}"
e_switch_and_commit() { git -C "$R14" checkout -q feat/e; mklines "mine" 7 > "$R14/mine.txt"
                        git -C "$R14" add -A >/dev/null; git -C "$R14" commit -qm "mine: small"; }
e_second()            { mklines "more" 500 > "$R14/more.txt"; git -C "$R14" add -A >/dev/null
                        git -C "$R14" commit -qm "mine: second"; }
tool_call "$SID_E" e_switch_and_commit
E_OUT="$(capture_git_prs "$WS14" "$SID_E" 2>/dev/null)"
[ "$(agg "$E_OUT")" = '{"lines_added":7,"lines_deleted":0,"files_changed":1,"commits":1}' ] \
  && ok "checkout-existing + commit in one call reports +7, not the previous job's +1200" \
  || bad "checkout-existing+commit reported $(agg "$E_OUT") — expected +7/1 file/1 commit"
[ "$(printf '%s' "$E_OUT" | jq -r '.[0].sha_start')" = "$E0" ] \
  && ok "anchored at the branch's sha when THIS session opened" \
  || bad "sha_start '$(printf '%s' "$E_OUT" | jq -r '.[0].sha_start')' != '$E0'"
tool_call "$SID_E" e_second
E2_OUT="$(capture_git_prs "$WS14" "$SID_E" 2>/dev/null)"
[ "$(agg "$E2_OUT")" = '{"lines_added":507,"lines_deleted":0,"files_changed":2,"commits":2}' ] \
  && ok "and a later commit adds to it (+507/2 files/2 commits) — the first is not dropped" \
  || bad "second commit lost the first: $(agg "$E2_OUT") — expected +507/2 files/2 commits"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
