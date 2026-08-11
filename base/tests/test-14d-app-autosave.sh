#!/usr/bin/env bash
# base/tests/test-14d-app-autosave.sh — guard for the SCRUM-1937 (SP-D) per-turn autosave +
# debounced staged publish that 14-claude-stop-hook.sh installs as sb-app-autosave.sh.
#
# Two things are being protected, and the second one matters more than the first:
#
#  1. THE FEATURE. An `app_edit_session` turn must produce a WIP autosave commit (so the
#     work survives a spot reclaim and shows up in jobs.prs), and must trigger exactly one
#     debounced staged publish. Every OTHER kind of turn — another workflow, a foreign
#     session, a clean tree, an expired marker — must produce nothing at all.
#
#  2. THE FLEET. The call site sits on the Stop hook's critical path, ahead of the usage and
#     step-complete POSTs that are the ONLY completion signal a job has. The hook runs under
#     `set -euo pipefail`, so an unguarded failure there would strand every job on every box
#     as `running`. The failure-injection section drives the REAL extracted Stop hook with a
#     helper that fails in each way it can (exit 1, exit 127, missing, and a real helper with
#     no git on PATH) and asserts both POSTs still go out every time.
#
# Sandboxed like test-14-git-capture.sh: temp HOME, real git repos, stub curl/node/npm on
# PATH, no network. Pure bash + git + jq (jq-dependent sections skip without it).
# Run: bash base/tests/test-14d-app-autosave.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. installer-level guards ────────────────────────────────────────────────────
bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"

grep -qF 'cat > "$AGENT_HOME/.local/bin/sb-app-autosave.sh"' "$HOOK" \
  && grep -qF 'chmod +x "$AGENT_HOME/.local/bin/sb-app-autosave.sh"' "$HOOK" \
  && ok "base/14 installs sb-app-autosave.sh executable" \
  || bad "sb-app-autosave.sh is not installed by base/14"

grep -qF 'sb-app-autosave.sh" mark "$SID"' "$HOOK" \
  && ok "SessionStart writer stamps the app-session marker (boot-turn race belt)" \
  || bad "sb-session-start.sh no longer marks the app session"

# The insert must be guarded AND must precede capture_git_prs, or the autosave commit misses
# the jobs.prs snapshot it exists to appear in.
grep -qF 'sb-app-autosave.sh" turn "$ENTRY_PATH" "$SESSION_ID" </dev/null >/dev/null 2>&1 || true' "$HOOK" \
  && ok "Stop-block call site is fully guarded (</dev/null, silenced, || true)" \
  || bad "the Stop-block call site lost its guards — a failure there strands jobs fleet-wide"

turn_ln=$(grep -n 'sb-app-autosave.sh" turn' "$HOOK" | head -1 | cut -d: -f1)
prs_ln=$(grep -n 'PRS_JSON=$(capture_git_prs' "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$turn_ln" ] && [ -n "$prs_ln" ] && [ "$turn_ln" -lt "$prs_ln" ]; then
  ok "autosave runs BEFORE capture_git_prs (commit lands in jobs.prs)"
else
  bad "autosave call ($turn_ln) is not ahead of capture_git_prs ($prs_ln)"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the helper + the Stop hook itself out of their heredocs (content anchors, so line
# drift in base/14 does not break this).
HELPER="$TMP/sb-app-autosave.sh"
awk "/cat > .*sb-app-autosave.sh.*<<'APPSAVEEOF'/{f=1;next} /^APPSAVEEOF\$/{f=0} f" "$HOOK" > "$HELPER"
chmod +x "$HELPER"
grep -q 'APP_WORKFLOW_ID="app_edit_session"' "$HELPER" \
  && ok "extracted sb-app-autosave.sh from the heredoc" \
  || bad "could not extract sb-app-autosave.sh from base/14"
bash -n "$HELPER" && ok "bash -n: sb-app-autosave.sh" || bad "bash -n failed on sb-app-autosave.sh"

grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$HELPER" \
  && bad "the helper sets -e — one non-zero step would abort it mid-way" \
  || ok "the helper never sets -e (every path reaches exit 0)"

STOPHOOK="$TMP/claude-stop-hook.sh"
awk "/cat > .*claude-stop-hook.sh.*<<'HOOKEOF'/{f=1;next} /^HOOKEOF\$/{f=0} f" "$HOOK" > "$STOPHOOK"
chmod +x "$STOPHOOK"
bash -n "$STOPHOOK" && ok "bash -n: claude-stop-hook.sh" || bad "bash -n failed on the extracted Stop hook"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — skipping every behavioural section (CI runs them)"
  echo
  if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
  exit "$fail"
fi

# ── stubs: no network, no real build, and a record of every call ─────────────────
STUB="$TMP/stub"; mkdir -p "$STUB"
CALLS="$TMP/calls.log"; : > "$CALLS"
cat > "$STUB/curl" <<'CURLEOF'
#!/usr/bin/env bash
url=""; body=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    @*)    body="${a#@}" ;;
  esac
done
echo "curl ${url}" >> "$CALLS"
[ -n "$body" ] && [ -f "$body" ] && cp "$body" "$LASTBODY" 2>/dev/null
# Test hook (B5b): arm ONE "a turn landed while we were publishing" flag, on the first POST only,
# so the drain loop is exercised the way the real race produces it.
if [ -n "${SB_TEST_ARM_PENDING:-}" ] && [ ! -f "${SB_TEST_ARM_ONCE}" ]; then
  : > "${SB_TEST_ARM_ONCE}" 2>/dev/null; : > "${SB_TEST_ARM_PENDING}" 2>/dev/null
fi
# Emulate -o <file> so the caller can read a response, and -w '%{http_code}'.
prev=""; for a in "$@"; do
  [ "$prev" = "-o" ] && printf '{"domain":"lp-x.sidebutton.com","url":"https://lp-x.sidebutton.com","release_ts":"20260810-000000","unchanged":true}' > "$a"
  prev="$a"
done
printf '200'
exit 0
CURLEOF
cat > "$STUB/npm" <<'NPMEOF'
#!/usr/bin/env bash
echo "npm $*" >> "$CALLS"
exit 0
NPMEOF
cat > "$STUB/node" <<'NODEEOF'
#!/usr/bin/env bash
echo "node $*" >> "$CALLS"
echo "Published. domain=lp-x.sidebutton.com release_ts=20260810-000000"
exit 0
NODEEOF
chmod +x "$STUB"/*
export CALLS LASTBODY="$TMP/last-body.json"
export PATH="$STUB:$PATH"

# ── sandbox: HOME with .agent-env + a workspace repo ─────────────────────────────
export HOME="$TMP/home"
WS="$HOME/workspace"; REPO="$WS/myproject"
mkdir -p "$REPO" "$HOME/.sidebutton"
cat > "$HOME/.agent-env" <<ENVEOF
export AGENT_TOKEN="tok-test"
export AGENT_NAME="agent-test"
export PORTAL_URL="http://portal.test"
export SB_APP_PUBLISH_MIN_INTERVAL=2
ENVEOF
git -C "$REPO" init -q -b work
git -C "$REPO" config user.email t@t.io; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base

reset_state() { rm -f "$HOME/.sidebutton/app-session.json" "$HOME/.sidebutton/job-context.json" \
                      "$HOME/.sidebutton/last-app-publish"; rm -rf "$HOME/.sidebutton/app-publish.lock"; }
job_ctx()  { printf '{"session_id":"%s","entry_path":"~/workspace","workflow_id":"%s"}' "$2" "$1" \
               > "$HOME/.sidebutton/job-context.json"; }
dirty()    { printf 'dirty %s\n' "$RANDOM" >> "$REPO/f"; }
head_of()  { git -C "$REPO" rev-parse HEAD; }
# `turn` spawns its detached half; every assertion below must see that half finished, or the
# test races its own background publisher (and its single-flight lock).
settle()   {
  local i
  command -v pgrep >/dev/null 2>&1 || { sleep 3; return 0; }
  for i in $(seq 1 150); do
    pgrep -u "$(id -u)" -f "$HELPER defer" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  return 0
}
turn()     { "$HELPER" turn "$WS" "$1" >/dev/null 2>&1; settle; }

# ── A. the gate matrix ───────────────────────────────────────────────────────────
# A1 boot turn: job-context says app_edit_session and the sid matches → commit + marker.
reset_state; job_ctx app_edit_session sidA; dirty; before=$(head_of)
turn sidA
[ "$(head_of)" != "$before" ] && ok "A1 boot turn: dirty tree → autosave commit" \
  || bad "A1 boot turn produced no commit"
[ "$(jq -r '.session_id' "$HOME/.sidebutton/app-session.json" 2>/dev/null)" = "sidA" ] \
  && ok "A1 boot turn writes the app-session marker" || bad "A1 marker not written"
git -C "$REPO" log -1 --pretty=%s | grep -q '\[sb-autosave\]' \
  && ok "A1 commit subject carries the [sb-autosave] tag" || bad "A1 commit is not tagged"

# A2 chat turn: job-context is GONE (the boot job completed) but the marker matches → commit.
rm -f "$HOME/.sidebutton/job-context.json"
dirty; before=$(head_of)
turn sidA
[ "$(head_of)" != "$before" ] \
  && ok "A2 chat turn (no job-context, marker sid matches) → autosave commit" \
  || bad "A2 chat turn produced no commit — the sticky marker is not working"

# A3 clean tree → nothing.
before=$(head_of)
turn sidA
[ "$(head_of)" = "$before" ] && ok "A3 clean tree → no empty commit" || bad "A3 committed a clean tree"

# A4 foreign session id → nothing (marker belongs to sidA).
dirty; before=$(head_of)
turn sidOTHER
[ "$(head_of)" = "$before" ] && ok "A4 foreign session id → no commit" || bad "A4 committed for a foreign session"

# A5 another workflow owns the box → nothing, even with a matching marker.
job_ctx agent_se_work sidA; before=$(head_of)
turn sidA
[ "$(head_of)" = "$before" ] && ok "A5 non-app workflow → no commit" || bad "A5 committed during another workflow"
rm -f "$HOME/.sidebutton/job-context.json"

# A6 expired marker (older than the 24h TTL) → nothing.
old=$(( $(date +%s) - 90000 ))
jq -nc --argjson s "$old" '{session_id:"sidA",entry_path:"'"$WS"'",workflow_id:"app_edit_session",started_at_epoch:$s,updated_at_epoch:$s}' \
  > "$HOME/.sidebutton/app-session.json"
before=$(head_of)
turn sidA
[ "$(head_of)" = "$before" ] && ok "A6 marker past the 24h TTL → no commit" || bad "A6 committed on an expired marker"

# A7 detached HEAD → skipped (a commit there would be unreachable).
reset_state; job_ctx app_edit_session sidA
git -C "$REPO" checkout -q --detach
before=$(head_of)
turn sidA
[ "$(head_of)" = "$before" ] && ok "A7 detached HEAD → skipped" || bad "A7 committed on a detached HEAD"
git -C "$REPO" checkout -q work

# A8 an in-progress git operation → skipped (never resolve someone's merge with `add -A`).
reset_state; job_ctx app_edit_session sidA; dirty
git -C "$REPO" rev-parse HEAD > "$(git -C "$REPO" rev-parse --absolute-git-dir)/MERGE_HEAD"
before=$(head_of)
turn sidA
[ "$(head_of)" = "$before" ] && ok "A8 merge in progress → skipped" || bad "A8 committed over an in-progress merge"
rm -f "$(git -C "$REPO" rev-parse --absolute-git-dir)/MERGE_HEAD"

# A9 the kill switch.
reset_state; job_ctx app_edit_session sidA; before=$(head_of)
SB_APP_AUTOSAVE_DISABLE=1 "$HELPER" turn "$WS" sidA >/dev/null 2>&1; settle
[ "$(head_of)" = "$before" ] && ok "A9 SB_APP_AUTOSAVE_DISABLE=1 → no commit" || bad "A9 kill switch does not stop the lane"

# A10 the project's own commit hooks must NOT gate the snapshot. husky + lint-staged is the norm in
# exactly the scaffolded projects this lane serves; a lint error on half-written WIP would otherwise
# fail every commit and silently disable durability for the whole session.
reset_state; job_ctx app_edit_session sidA
HOOKDIR="$(git -C "$REPO" rev-parse --absolute-git-dir)/hooks"; mkdir -p "$HOOKDIR"
printf '#!/bin/sh\necho "lint failed" >&2\nexit 1\n' > "$HOOKDIR/pre-commit"; chmod +x "$HOOKDIR/pre-commit"
dirty; before=$(head_of)
turn sidA
[ "$(head_of)" != "$before" ] \
  && ok "A10 a failing pre-commit hook does not block the autosave (--no-verify)" \
  || bad "A10 the project's pre-commit hook silently disabled durability for the session"
rm -f "$HOOKDIR/pre-commit"

# A11 `git add -A` sweeps in whatever the project does not ignore, and the detached half force-
# pushes the result to the repo's OWN origin — so an untracked credential must never enter the
# snapshot. A secret the repo already tracks is the project's own choice and stays untouched.
reset_state; job_ctx app_edit_session sidA
printf 'API_KEY=super-secret\n' > "$REPO/.env"
printf 'PRIVATE\n' > "$REPO/server.pem"
dirty; before=$(head_of)
turn sidA
[ "$(head_of)" != "$before" ] || bad "A11 no autosave commit was produced at all"
git -C "$REPO" ls-tree -r --name-only HEAD | grep -qx '.env' \
  && bad "A11 an untracked .env was committed and is force-pushed to the customer's origin" \
  || ok "A11 an untracked .env is excluded from the autosave snapshot"
git -C "$REPO" ls-tree -r --name-only HEAD | grep -qx 'server.pem' \
  && bad "A11 an untracked private key was committed" \
  || ok "A11 an untracked .pem is excluded from the autosave snapshot"
[ -f "$REPO/.env" ] && ok "A11 the excluded secret is left in the worktree, not destroyed" \
  || bad "A11 the excluded secret was removed from the worktree"
rm -f "$REPO/.env" "$REPO/server.pem"

# A12 THE fleet-critical case: the Stop hook declares no timeout, so Claude Code's 60s default bounds
# the WHOLE hook and the completion POSTs come after this lane. A git that HANGS (huge untracked
# tree, cold cache after a spot resume) must not eat that budget — every git call is bounded and the
# half as a whole abandons at COMMIT_BUDGET. The other injection tests only cover git EXITING badly.
reset_state; job_ctx app_edit_session sidA; dirty
HANG="$TMP/hangbin"; mkdir -p "$HANG"
printf '#!/bin/sh\nsleep 300\n' > "$HANG/git"; chmod +x "$HANG/git"
t0=$(date +%s)
PATH="$HANG:$PATH" "$HELPER" turn "$WS" sidA >/dev/null 2>&1; rc=$?
t1=$(date +%s)
[ "$rc" = "0" ] && ok "A12 a hanging git still exits 0" || bad "A12 the helper exited $rc on a hanging git"
[ $((t1 - t0)) -le 40 ] \
  && ok "A12 a hanging git is abandoned inside the hook budget ($((t1 - t0))s)" \
  || bad "A12 a hanging git held the critical path for $((t1 - t0))s — the hook would be killed"
settle

# ── B. the deferred half: scratch push, then the debounced publish ───────────────
# B0 the commit half must contain NO network call. It runs inside Claude Code's 60s hook
# budget ahead of the completion POSTs; a blocking push there could get the whole hook
# killed and strand the job — the precise failure mode this feature must not introduce.
awk '/^autosave_commit\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$HELPER" \
  | grep -vE '^[[:space:]]*#' > "$TMP/commit-half.sh"   # code only — the comments say "push"
grep -qE '\bpush\b|\bcurl\b|\bfetch\b' "$TMP/commit-half.sh" \
  && bad "B0 the synchronous commit half makes a network call" \
  || ok "B0 the commit half is local-only (the push is queued for the detached half)"
grep -qF 'drain_push_queue' "$HELPER" && ok "B0 a deferred push drain exists" || bad "B0 no push drain"

# B0b the scratch push targets sb-autosave/<branch> and never the real branch.
reset_state
BARE="$TMP/origin.git"; git init -q --bare "$BARE"
git -C "$REPO" remote add origin "$BARE" 2>/dev/null || git -C "$REPO" remote set-url origin "$BARE"
job_ctx app_edit_session sidA; dirty
turn sidA
git -C "$BARE" show-ref --verify --quiet refs/heads/sb-autosave/work \
  && ok "B0b the autosave commit is mirrored to origin sb-autosave/<branch>" \
  || bad "B0b the scratch ref was never pushed — a reclaim still eats the turn"
git -C "$BARE" show-ref --verify --quiet refs/heads/work \
  && bad "B0b the real branch was pushed — the scratch namespace was bypassed" \
  || ok "B0b the real branch is left untouched"
[ -s "$HOME/.sidebutton/app-autosave-push-queue" ] \
  && bad "B0b the push queue was not drained" || ok "B0b the push queue is drained after the push"

# B0c a FAILED push must be re-queued. The queue is destructive-on-read, so without a re-queue a
# single transient failure (network blip, expired credential, a 5xx) strands that commit on the box
# until some later turn happens to commit again — and a reclaim right after the session's last turn
# is exactly the loss this feature exists to prevent.
reset_state
git -C "$REPO" remote set-url origin "$TMP/nope.git"    # a remote that cannot be pushed to
job_ctx app_edit_session sidA; dirty
turn sidA
grep -qxF "$REPO" "$HOME/.sidebutton/app-autosave-push-queue" 2>/dev/null \
  && ok "B0c a failed scratch push is re-queued for the next turn" \
  || bad "B0c a failed push dropped the repo from the queue — that commit is stranded on the VM"
grep -q 're-queued' "$HOME/.sidebutton/app-autosave.log" \
  && ok "B0c the failure is logged" || bad "B0c the push failure was not logged"
rm -f "$HOME/.sidebutton/app-autosave-push-queue"
git -C "$REPO" remote remove origin 2>/dev/null

git -C "$REPO" checkout -q -- . 2>/dev/null; git -C "$REPO" clean -qfd 2>/dev/null

# B1 kit path: a project carrying the real landing client is delegated to, after a build.
mkdir -p "$REPO/scripts"
printf '{"name":"p","scripts":{"build":"true"}}' > "$REPO/package.json"
printf 'fetch("/api/agents/landing/publish")\n' > "$REPO/scripts/publish.mjs"
reset_state; : > "$CALLS"
"$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q '^npm run build' "$CALLS" && ok "B1 runs the project build before publishing" || bad "B1 no build ran"
grep -q '^node scripts/publish.mjs' "$CALLS" && ok "B1 delegates to the landing kit client" \
  || bad "B1 did not delegate to scripts/publish.mjs"
[ -f "$HOME/.sidebutton/last-app-publish" ] && ok "B1 stamps last-app-publish" || bad "B1 no debounce stamp written"

# B2 a same-named script that is NOT our client is never executed.
printf 'console.log("something else entirely")\n' > "$REPO/scripts/publish.mjs"
mkdir -p "$REPO/dist"; printf '<html></html>' > "$REPO/dist/index.html"
reset_state; : > "$CALLS"
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q '^node scripts/publish.mjs' "$CALLS" \
  && bad "B2 executed an unrelated scripts/publish.mjs" \
  || ok "B2 an unrelated scripts/publish.mjs is not executed"

# B3 generic fallback: dist/ is POSTed as {slug, files:[{path, content_b64}]}.
grep -q 'curl http://portal.test/api/agents/landing/publish' "$CALLS" \
  && ok "B3 generic path POSTs to /api/agents/landing/publish" \
  || bad "B3 no publish POST from the generic path"
if [ -f "$LASTBODY" ]; then
  [ "$(jq -r '.slug' "$LASTBODY")" = "acme" ] && ok "B3 payload carries the slug" || bad "B3 wrong slug in the payload"
  [ "$(jq -r '.files[0].path' "$LASTBODY")" = "index.html" ] \
    && ok "B3 payload files[] are release-root-relative paths" || bad "B3 wrong file path in the payload"
  [ -n "$(jq -r '.files[0].content_b64' "$LASTBODY")" ] && ok "B3 payload carries content_b64" \
    || bad "B3 content_b64 missing"
else
  bad "B3 no request body captured"
fi
# SP-H says to read `unchanged`, not release_ts — so the log must record it faithfully.
# jq's `//` treats false as absent, and false ("a release WAS written") is the value that
# matters most; it must never be logged as unknown.
grep -q 'unchanged=true' "$HOME/.sidebutton/app-autosave.log" \
  && ok "B3 the response's unchanged flag is logged verbatim (SP-H assert-on-unchanged)" \
  || bad "B3 unchanged was not logged from the publish response"
: > "$TMP/resp-false.json"
printf '{"domain":"d","url":"u","release_ts":"t","unchanged":false}' > "$TMP/resp-false.json"
[ "$(jq -r 'if has("unchanged") then (.unchanged|tostring) else "absent" end' "$TMP/resp-false.json")" = "false" ] \
  && ok "B3 unchanged:false reads back as false, not as a missing field" \
  || bad "B3 the unchanged reader collapses false to absent"

# B4 no slug and no kit client → skip rather than guess.
reset_state; : > "$CALLS"; rm -f "$LASTBODY"
"$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q 'landing/publish' "$CALLS" && bad "B4 published without a resolvable slug" \
  || ok "B4 no LANDING_SLUG and no kit client → skipped, not guessed"

# B5 single-flight: a pending publisher swallows the new request (no second POST).
reset_state; mkdir -p "$HOME/.sidebutton/app-publish.lock"; : > "$CALLS"
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q 'landing/publish' "$CALLS" && bad "B5 a second publisher ran while one was pending" \
  || ok "B5 single-flight: a pending publish coalesces the next turn"
grep -q 'trailing pass' "$HOME/.sidebutton/app-autosave.log" && ok "B5 the coalesce is logged" || bad "B5 not logged"
# The coalesced turn must LEAVE A MARK. Dropping it outright is only safe while the holder is still
# in its debounce; once the holder is building or POSTing it has already read the tree, so without
# this flag the coalesced turn's edits would never be published (worst on a session's last turn).
[ -f "$HOME/.sidebutton/app-publish-pending" ] \
  && ok "B5 the coalesced turn flags a trailing pass instead of being dropped" \
  || bad "B5 the coalesced turn left no pending flag — its edits would never publish"

# B5b the lock holder drains that flag: a turn that lands mid-publish still gets published.
reset_state; : > "$CALLS"; rm -f "$LASTBODY" "$TMP/arm-once"
LANDING_SLUG=acme SB_APP_PUBLISH_MIN_INTERVAL=0 \
  SB_TEST_ARM_PENDING="$HOME/.sidebutton/app-publish-pending" SB_TEST_ARM_ONCE="$TMP/arm-once" \
  "$HELPER" publish "$WS" sidA >/dev/null 2>&1
[ "$(grep -c 'landing/publish' "$CALLS" 2>/dev/null)" -ge 2 ] \
  && ok "B5b a turn that landed mid-publish is drained by a trailing pass" \
  || bad "B5b the pending flag was not drained — the last turn's edits are lost"
[ -f "$HOME/.sidebutton/app-publish-pending" ] \
  && bad "B5b the pending flag survived its own drain (would re-publish forever)" \
  || ok "B5b the pending flag is cleared once drained"

# B5c the lock is released only by its OWNER: a publisher whose lock was broken as stale must not
# delete the lock a NEW publisher now holds, or two builds + POSTs race in the same project.
reset_state
mkdir -p "$HOME/.sidebutton/app-publish.lock"
echo "someone-else" > "$HOME/.sidebutton/app-publish.lock/owner"
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
[ "$(cat "$HOME/.sidebutton/app-publish.lock/owner" 2>/dev/null)" = "someone-else" ] \
  && ok "B5c a coalesced publisher never removes the live holder's lock" \
  || bad "B5c the live holder's lock was destroyed by another process"

# B6 stale lock is broken so the lane cannot be silenced forever by a dead publisher.
touch -d '3 hours ago' "$HOME/.sidebutton/app-publish.lock" 2>/dev/null
: > "$CALLS"
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q 'landing/publish' "$CALLS" && ok "B6 a stale lock is broken and the publish proceeds" \
  || bad "B6 stale lock permanently blocks publishing"
rm -rf "$HOME/.sidebutton/app-publish.lock"

# B7 trailing catch-up: inside the debounce window the publisher WAITS, then fires once.
reset_state; date +%s > "$HOME/.sidebutton/last-app-publish"; : > "$CALLS"
t0=$(date +%s)
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
elapsed=$(( $(date +%s) - t0 ))
[ "$elapsed" -ge 2 ] && ok "B7 inside the window the publish is deferred (${elapsed}s), not dropped" \
  || bad "B7 published immediately inside the debounce window (${elapsed}s)"
[ "$(grep -c 'landing/publish' "$CALLS")" = "1" ] && ok "B7 the deferred publish fires exactly once" \
  || bad "B7 expected exactly one deferred POST, got $(grep -c 'landing/publish' "$CALLS")"

# B8 floor gate (SCRUM-1965): a project that ships through git must NOT also claim a landing slug.
# The v2 session contract ends every turn with a commit pushed to the project's branch, so a floor
# republish here would mint a second durable copy of the same work — an lp-<name> site nobody asked
# for — and leave the user with two answers to "where did my work go". Everything above this line
# runs against a repo whose origin was removed, which is exactly the un-gated (landing-kit) lane.
reset_state; : > "$CALLS"
git -C "$REPO" remote add origin "$BARE" 2>/dev/null
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q 'landing/publish' "$CALLS" \
  && bad "B8 a repo project published to the landing floor — it now has two durable lanes" \
  || ok "B8 a project with an origin remote does not publish to the landing floor"
grep -q '^npm run build' "$CALLS" \
  && bad "B8 the gate ran after the build — a skipped project must cost nothing" \
  || ok "B8 the gate skips before the build, so a repo project costs nothing here"
grep -q 'durable lane is git' "$HOME/.sidebutton/app-autosave.log" \
  && ok "B8 the skip says why in the log" || bad "B8 the skip is silent — undebuggable in the field"
[ -f "$HOME/.sidebutton/last-app-publish" ] \
  && bad "B8 a skipped publish still stamped the debounce floor" \
  || ok "B8 the skip leaves the debounce stamp alone"

# B8b the same project without a remote still publishes: the gate keys on the remote, nothing else.
git -C "$REPO" remote remove origin 2>/dev/null
reset_state; : > "$CALLS"
LANDING_SLUG=acme "$HELPER" publish "$WS" sidA >/dev/null 2>&1
grep -q 'landing/publish' "$CALLS" \
  && ok "B8b a remote-less project still auto-republishes (the Phase-1 landing lane is untouched)" \
  || bad "B8b the gate broke the landing-kit lane it was supposed to leave alone"

# ── C. failure injection on the critical path ────────────────────────────────────
# The whole point: whatever the autosave lane does, the two completion POSTs must go out.
git -C "$REPO" checkout -q -- . 2>/dev/null; git -C "$REPO" clean -qfd 2>/dev/null
mkdir -p "$HOME/.local/bin"
TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}\n' > "$TRANSCRIPT"

run_stop() {  # run_stop <label> — one main-agent Stop; echoes nothing, records curl calls
  : > "$CALLS"
  printf '{"session_id":"sidA","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s"}' \
    "$TRANSCRIPT" "$WS" | bash "$STOPHOOK" >/dev/null 2>&1
  echo "$?"
}
assert_completion() {  # assert_completion <label> <exit_code>
  local label="$1" rc="$2"
  [ "$rc" = "0" ] && ok "C $label: the Stop hook still exits 0" || bad "C $label: hook exited $rc"
  grep -q '/api/jobs/usage' "$CALLS"         && ok "C $label: usage POST still sent" \
    || bad "C $label: THE USAGE POST WAS LOST"
  grep -q '/api/jobs/step-complete' "$CALLS" && ok "C $label: step-complete POST still sent" \
    || bad "C $label: THE STEP-COMPLETE POST WAS LOST — jobs would strand as running"
}

reset_state; job_ctx app_edit_session sidA
printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME/.local/bin/sb-app-autosave.sh"
chmod +x "$HOME/.local/bin/sb-app-autosave.sh"
assert_completion "helper exits 1" "$(run_stop)"

printf '#!/nonexistent/interpreter\n' > "$HOME/.local/bin/sb-app-autosave.sh"
chmod +x "$HOME/.local/bin/sb-app-autosave.sh"
assert_completion "helper cannot exec (127)" "$(run_stop)"

printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$HOME/.local/bin/sb-app-autosave.sh"
chmod +x "$HOME/.local/bin/sb-app-autosave.sh"
assert_completion "helper writes to stderr and exits 3" "$(run_stop)"

rm -f "$HOME/.local/bin/sb-app-autosave.sh"
assert_completion "helper not installed (pre-refresh box)" "$(run_stop)"

# The real helper, with git removed from PATH — it must degrade to a no-op, not a hang/abort.
cp "$HELPER" "$HOME/.local/bin/sb-app-autosave.sh"; chmod +x "$HOME/.local/bin/sb-app-autosave.sh"
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
for b in bash jq date cat find wc sed awk grep mktemp gzip basename tr rm mv mkdir rmdir sort head tail stat sleep touch printf env dirname timeout setsid; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NOGIT/$b" 2>/dev/null
done
ln -sf "$STUB/curl" "$NOGIT/curl"
dirty
rc=$( : > "$CALLS"; printf '{"session_id":"sidA","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s"}' \
        "$TRANSCRIPT" "$WS" | PATH="$NOGIT" bash "$STOPHOOK" >/dev/null 2>&1; echo $? )
assert_completion "real helper with no git on PATH" "$rc"

# And with the real helper on a genuine app turn, the completion POSTs coexist with the commit.
export PATH="$STUB:$PATH"
reset_state; job_ctx app_edit_session sidA; dirty; before=$(head_of)
rc=$(run_stop)
assert_completion "real helper on a live app turn" "$rc"
[ "$(head_of)" != "$before" ] && ok "C the live app turn also produced its autosave commit" \
  || bad "C the autosave commit did not happen on a real Stop"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
