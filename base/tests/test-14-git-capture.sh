#!/usr/bin/env bash
# base/tests/test-14-git-capture.sh — regression guard for the SCRUM-513 git-telemetry
# capture path in 14-claude-stop-hook.sh.
#
# capture_git_prs() discovers the git repos under the job's workspace and emits the
# jobs.prs JSON the portal stores. The workspace path comes from job-context as the
# literal "~/workspace" (a tilde, not an absolute path). `git -C "~/workspace"` and the
# subdir glob never expand ~, so on the live fleet capture found ZERO repos and NO git
# telemetry was ever recorded (jobs.prs empty fleet-wide) even though usage/transcript
# from the same Stop hook landed fine. The fix expands a leading ~ to $HOME. This test
# proves a tilde workspace path is discovered exactly like the absolute one, and that
# the unfixed literal-tilde behaviour finds nothing.
#
# Pure bash + git. The JSON-shape assertions also need jq (present on CI; a jq-less
# local run still proves the discovery fix + reproduces the bug, and runs bash -n).
# Run: bash base/tests/test-14-git-capture.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
HOOK="$BASE/14-claude-stop-hook.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

# ── 0. the installer must stay syntactically valid + carry the fix ───────────────
bash -n "$HOOK" && ok "bash -n: 14-claude-stop-hook.sh" || bad "bash -n failed on the hook"
grep -qF 'entry="${entry/#\~/$HOME}"' "$HOOK" \
  && ok "capture_git_prs carries the ~-expansion fix" \
  || bad "the ~-expansion fix is missing from capture_git_prs"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the two pure functions (normalize_repo_url + capture_git_prs) from the
# HOOKEOF heredoc so we can call capture_git_prs directly, without firing the whole
# Stop hook (which blocks on stdin and posts to the portal).
awk '/^normalize_repo_url\(\) \{/{p=1} p{print} /^capture_git_prs\(\) \{/{c=1} c&&/^\}/{exit}' "$HOOK" > "$TMP/funcs.sh"
grep -q '^capture_git_prs() {' "$TMP/funcs.sh" \
  && ok "extracted normalize_repo_url + capture_git_prs from the hook heredoc" \
  || bad "could not extract capture_git_prs from the hook"

# Build a fake workspace: $HOME/workspace/myrepo = a git repo with an origin remote
# and a 2-line diff vs its merge-base, so capture has real churn + a repo_url.
export HOME="$TMP/home"
WS="$HOME/workspace"; REPO="$WS/myrepo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.io; git -C "$REPO" config user.name t
git -C "$REPO" remote add origin https://github.com/acme/myrepo.git
printf 'a\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base
git -C "$REPO" update-ref refs/remotes/origin/HEAD HEAD   # so merge-base origin/HEAD resolves
printf 'a\nb\nc\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm change

# shellcheck source=/dev/null
. "$TMP/funcs.sh"

if command -v jq >/dev/null 2>&1; then
  TILDE_JSON="$(capture_git_prs '~/workspace' 2>/dev/null)"
  ABS_JSON="$(capture_git_prs "$WS" 2>/dev/null)"
  n_tilde="$(printf '%s' "$TILDE_JSON" | jq 'length' 2>/dev/null || echo x)"
  n_abs="$(printf '%s'  "$ABS_JSON"   | jq 'length' 2>/dev/null || echo y)"
  [ "$n_tilde" = "1" ] && ok "tilde workspace '~/workspace' discovers the repo (len=1)" \
    || bad "tilde path found '$n_tilde' repos, expected 1 — the fix is ineffective"
  [ "$n_abs" = "1" ] && ok "absolute workspace discovers the repo (control, len=1)" \
    || bad "absolute path found '$n_abs' repos, expected 1"
  url="$(printf '%s' "$TILDE_JSON" | jq -r '.[0].repo_url' 2>/dev/null)"
  [ "$url" = "https://github.com/acme/myrepo" ] && ok "repo_url captured + normalized (.git/trailing stripped)" \
    || bad "repo_url wrong: '$url'"
  [ "$TILDE_JSON" = "$ABS_JSON" ] && ok "tilde and absolute paths produce identical capture" \
    || bad "tilde output differs from absolute output"
else
  skip "jq not installed — running the jq-free discovery proof instead (CI runs the JSON assertions)"
  # Prove the FIX: an expanded ~ path discovers the repo subdir.
  e='~/workspace'; e="${e/#\~/$HOME}"
  found=0; for s in "$e"/*/; do [ -d "$s" ] && git -C "$s" rev-parse --show-toplevel >/dev/null 2>&1 && found=1; done
  [ "$found" = 1 ] && ok "jq-free: ~-expanded workspace discovers the repo subdir" \
    || bad "jq-free: discovery still fails after expansion"
  # Prove the BUG: the unfixed literal "~/workspace" finds nothing.
  raw='~/workspace'; rawfound=0
  git -C "$raw" rev-parse --show-toplevel >/dev/null 2>&1 && rawfound=1
  for s in "$raw"/*/; do [ -d "$s" ] && rawfound=1; done
  [ "$rawfound" = 0 ] && ok "jq-free: literal '~/workspace' finds nothing (reproduces the bug)" \
    || bad "jq-free: literal tilde unexpectedly matched a repo"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
