#!/usr/bin/env bash
# base/tests/test-18c-revert.sh — regression guard for the SCRUM-1394 false-revert fix in
# 18c-git-telemetry-timer.sh.
#
# The reconcile timer's revert scan used to flag a PR reverted when ANY base-branch commit's message
# both contained the word "revert" AND mentioned the PR number "#<n>". A squash-merge commit is
# "<title> (#<n>)", so a PR whose title merely mentioned revert (e.g. agent-runners #55, "…merge/revert…
# (#55)") matched its OWN merge commit and was stamped pr_reverted_at == pr_merged_at. The fix matches
# git's canonical "This reverts commit <mergeSHA>" body instead, and excludes the PR's own merge commit.
#
# This proves (a) the generated reconcile script is syntactically valid, (b) it carries the canonical
# match + merge-commit exclusion and dropped the revert+#num heuristic, and (c) the jq the script runs
# treats a squash-merge as NOT reverted but a real "This reverts commit <sha>" as reverted — on both
# the GitHub (.commit.message / .sha) and Bitbucket (.message / .hash) commit shapes.
# Run: bash base/tests/test-18c-revert.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/.."
STEP="$BASE/18c-git-telemetry-timer.sh"
fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }
skip() { printf 'skip - %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 0. installer + generated reconcile script stay syntactically valid ───────────
bash -n "$STEP" && ok "bash -n: 18c-git-telemetry-timer.sh" || bad "bash -n failed on the step"
awk "/cat > \/opt\/sb-git-telemetry.sh <<'EOF'/{f=1;next} /^EOF\$/{f=0} f" "$STEP" > "$TMP/recon.sh"
bash -n "$TMP/recon.sh" && ok "bash -n: generated /opt/sb-git-telemetry.sh" || bad "bash -n failed on the generated script"

# ── 1. carries the canonical revert match + merge-commit exclusion, dropped the #num heuristic ───
grep -qF 'This reverts commit ' "$TMP/recon.sh" \
  && ok "revert scan matches the canonical 'This reverts commit <sha>' body" \
  || bad "canonical revert match is missing"
grep -qF 'select(.sha != $sha)' "$TMP/recon.sh" \
  && ok "GitHub scan excludes the PR's own merge commit (.sha != \$sha)" \
  || bad "GitHub merge-commit exclusion missing"
grep -qF 'select(.hash != $sha)' "$TMP/recon.sh" \
  && ok "Bitbucket scan excludes the PR's own merge commit (.hash != \$sha)" \
  || bad "Bitbucket merge-commit exclusion missing"
if grep -qF 'contains($num)' "$TMP/recon.sh"; then
  bad "the buggy revert+#num heuristic is still present (contains(\$num))"
else
  ok "dropped the revert+#num heuristic that matched the squash-merge commit"
fi

# ── 2. behavioral — MIRRORS the two jq filters in 18c (kept in lockstep by the greps above) ───────
if command -v jq >/dev/null 2>&1; then
  MSHA="f520f279abcdef0123456789abcdef0123456789"
  gh_scan() { jq -r --arg sha "$MSHA" '[ .[] | select(.sha != $sha) | .commit as $c | select(($c.message // "") | contains("This reverts commit " + $sha)) | $c.committer.date ] | .[0] // empty'; }
  bb_scan() { jq -r --arg sha "$MSHA" '[ .values[] | select(.hash != $sha) | select((.message // "") | contains("This reverts commit " + $sha)) | .date ] | .[0] // empty'; }

  # GitHub: only the merge commit mentions revert + (#55) -> NOT reverted
  gh_squash="$(printf '[{"sha":"%s","commit":{"message":"feat(base): resolve merge/revert (SCRUM-1392) (#55)","committer":{"date":"2026-06-22T16:31:45Z"}}}]' "$MSHA" | gh_scan)"
  [ -z "$gh_squash" ] && ok "GitHub: squash-merge whose title mentions revert is NOT reverted" \
    || bad "GitHub: squash-merge falsely flagged reverted ($gh_squash)"
  # GitHub: a later commit with the canonical body -> reverted
  gh_rev="$(printf '[{"sha":"%s","commit":{"message":"m (#55)","committer":{"date":"2026-06-22T16:31:45Z"}}},{"sha":"bbbb","commit":{"message":"Revert x. This reverts commit %s.","committer":{"date":"2026-06-23T09:00:00Z"}}}]' "$MSHA" "$MSHA" | gh_scan)"
  [ "$gh_rev" = "2026-06-23T09:00:00Z" ] && ok "GitHub: a real 'This reverts commit <sha>' IS reverted" \
    || bad "GitHub: real revert not detected ($gh_rev)"

  # Bitbucket shapes
  bb_squash="$(printf '{"values":[{"hash":"%s","message":"Merged in feat (pull request #55) revert handling","date":"2026-06-22T16:31:45Z"}]}' "$MSHA" | bb_scan)"
  [ -z "$bb_squash" ] && ok "Bitbucket: squash-merge mentioning revert is NOT reverted" \
    || bad "Bitbucket: squash-merge falsely flagged reverted ($bb_squash)"
  bb_rev="$(printf '{"values":[{"hash":"%s","message":"m","date":"2026-06-22T16:31:45Z"},{"hash":"dddd","message":"Revert. This reverts commit %s.","date":"2026-06-23T10:00:00Z"}]}' "$MSHA" "$MSHA" | bb_scan)"
  [ "$bb_rev" = "2026-06-23T10:00:00Z" ] && ok "Bitbucket: a real 'This reverts commit <sha>' IS reverted" \
    || bad "Bitbucket: real revert not detected ($bb_rev)"
else
  skip "jq not installed — skipping behavioral revert-scan assertions"
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
