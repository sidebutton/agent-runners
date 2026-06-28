#!/usr/bin/env bash
# base/tests/run-all.sh — discover + run the base/tests regression suite (SCRUM-1447, T4).
#
# Auto-discovers base/tests/test-*.sh (so a new guard is picked up with no edit here),
# runs each, prints a per-file PASS/FAIL line, dumps the output of any failure, and
# exits non-zero if any test failed.
#
# By default it SKIPS the tests listed in base/tests/ci-exclude.txt (each with a
# documented reason) — those are guards that are not hermetic on a generic / CI
# runner. Pass --all to run absolutely everything (e.g. on a fully provisioned VM).
#
#   bash base/tests/run-all.sh          # default + CI suite (honors ci-exclude.txt)
#   bash base/tests/run-all.sh --all    # every test-*.sh, no exclusions
#
# Pure bash + jq (jq used by the individual guards). Run from anywhere.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXCLUDE_FILE="$SCRIPT_DIR/ci-exclude.txt"

RUN_ALL=0
[ "${1:-}" = "--all" ] && RUN_ALL=1

is_excluded() {
  [ "$RUN_ALL" = 1 ] && return 1
  [ -f "$EXCLUDE_FILE" ] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_FILE" | grep -qx "$1"
}

pass=0; failc=0; skip=0
failed=()
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

shopt -s nullglob
tests=("$SCRIPT_DIR"/test-*.sh)
shopt -u nullglob

if [ "${#tests[@]}" -eq 0 ]; then
  echo "run-all: no test-*.sh found in $SCRIPT_DIR" >&2
  exit 1
fi

echo "== base/tests suite ($([ "$RUN_ALL" = 1 ] && echo 'all' || echo 'default/CI') mode) =="
for t in "${tests[@]}"; do
  b="$(basename "$t")"
  if is_excluded "$b"; then
    printf 'SKIP - %s (ci-exclude.txt)\n' "$b"
    skip=$((skip+1))
    continue
  fi
  if bash "$t" >"$tmp" 2>&1; then
    printf 'PASS - %s\n' "$b"
    pass=$((pass+1))
  else
    printf 'FAIL - %s\n' "$b"
    sed 's/^/        | /' "$tmp"
    failc=$((failc+1))
    failed+=("$b")
  fi
done

echo "-----------------------------------------------"
printf 'tally: %d passed, %d failed, %d skipped\n' "$pass" "$failc" "$skip"
if [ "$failc" -ne 0 ]; then
  printf 'failed: %s\n' "${failed[*]}"
  exit 1
fi
echo "SUITE GREEN"
