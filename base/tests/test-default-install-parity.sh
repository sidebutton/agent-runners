#!/usr/bin/env bash
# base/tests/test-default-install-parity.sh — guard for SCRUM-1447 (T4, AC3).
#
# The componentization made claude-code an EXPLICIT catalog entry, but a default /
# empty / back-compat agent must still resolve to a BYTE-IDENTICAL set of step gates
# (claude-code default-on; no server/packs/chrome/extension). This pins the resolver
# (base/components.sh) by sourcing it headlessly under a set of canonical inputs and
# diffing the derived gate vector against a committed golden snapshot — so any future
# change to the gate logic must be reviewed (and re-blessed), not slipped in.
#
# Gate vector captured per input:
#   INSTALL_CLAUDE_CODE INSTALL_CHROME INSTALL_EXTENSION SKIP_SIDEBUTTON_SERVER SKIP_KNOWLEDGE_PACKS
# Inputs: AGENT_COMPONENTS unset / "" / "   " (the three back-compat spellings of
# "manual base agent") + every profiles.json profile's component list (dynamic — a
# new/edited profile shifts the snapshot and forces a re-bless).
#
# Re-bless after an INTENTIONAL gate change:  BLESS=1 bash base/tests/test-default-install-parity.sh
#
# Complements (does not duplicate) test-claude-code-install.sh, which owns the
# claude-code gate's AC1/2/3 in isolation; this is the whole-vector superset.
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-default-install-parity.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_SH="$ROOT/base/components.sh"
PROFILES="$ROOT/profiles.json"
SNAP="$SCRIPT_DIR/fixtures/default-install.snapshot"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# Source components.sh in an isolated subshell with a stubbed `log` and a clean env
# (no inherited AGENT_COMPONENTS/SIDEBUTTON_PLUGINS), then echo the derived gates.
gates() { # arg: AGENT_COMPONENTS value, or the literal __unset__
  ( log() { :; }
    unset SIDEBUTTON_PLUGINS
    if [ "$1" = "__unset__" ]; then unset AGENT_COMPONENTS; else export AGENT_COMPONENTS="$1"; fi
    # shellcheck disable=SC1090
    . "$COMPONENTS_SH" >/dev/null 2>&1
    printf 'INSTALL_CLAUDE_CODE=%s INSTALL_CHROME=%s INSTALL_EXTENSION=%s SKIP_SIDEBUTTON_SERVER=%s SKIP_KNOWLEDGE_PACKS=%s' \
      "${INSTALL_CLAUDE_CODE:-?}" "${INSTALL_CHROME:-?}" "${INSTALL_EXTENSION:-?}" \
      "${SKIP_SIDEBUTTON_SERVER:-?}" "${SKIP_KNOWLEDGE_PACKS:-?}" )
}

# Deterministic snapshot text: the three manual spellings (fixed order) then every
# profile (sorted, so profile order in profiles.json doesn't churn the golden).
build_snapshot() {
  printf '%s\t%s\n' "__unset__"      "$(gates __unset__)"
  printf '%s\t%s\n' "__empty__"      "$(gates "")"
  printf '%s\t%s\n' "__whitespace__" "$(gates "   ")"
  while IFS=$'\t' read -r slug comps; do
    printf 'profile:%s\t%s\n' "$slug" "$(gates "$comps")"
  done < <(jq -r '.profiles[] | "\(.slug)\t\(.components|join(" "))"' "$PROFILES" | sort)
}

CURRENT="$(build_snapshot)"

# ── BLESS mode: (re)write the golden and exit ────────────────────────────────
if [ "${BLESS:-0}" = "1" ]; then
  mkdir -p "$(dirname "$SNAP")"
  printf '%s\n' "$CURRENT" > "$SNAP"
  echo "blessed $SNAP:"
  printf '%s\n' "$CURRENT" | sed 's/^/    /'
  exit 0
fi

# ── 1. the gate vector matches the committed golden ──────────────────────────
if [ ! -f "$SNAP" ]; then
  bad "snapshot missing: $SNAP (regenerate with BLESS=1 bash $(basename "$0"))"
elif diff -u "$SNAP" <(printf '%s\n' "$CURRENT") >/dev/null 2>&1; then
  ok "derived gate vector is byte-identical to the committed snapshot"
else
  bad "gate vector DRIFTED from the snapshot (review, then re-bless with BLESS=1):"
  diff -u "$SNAP" <(printf '%s\n' "$CURRENT") | sed 's/^/    /'
fi

# ── 2. explicit back-compat invariants (the point of the snapshot, asserted plainly)
for spelling in __unset__ "" "   "; do
  label="$spelling"; [ "$spelling" = "__unset__" ] && label="unset"; [ -z "$spelling" ] && label="empty"; [ "$spelling" = "   " ] && label="whitespace"
  case "$(gates "$spelling")" in
    *"INSTALL_CLAUDE_CODE=1"*) ok "back-compat: AGENT_COMPONENTS $label => INSTALL_CLAUDE_CODE=1" ;;
    *) bad "back-compat: AGENT_COMPONENTS $label did NOT yield INSTALL_CLAUDE_CODE=1" ;;
  esac
done

# ── 3. the default profile must list claude-code (its default-on is real, not implicit)
DEF="$(jq -r '.default' "$PROFILES")"
jq -e --arg d "$DEF" '.profiles[]|select(.slug==$d)|.components|index("claude-code")' "$PROFILES" >/dev/null 2>&1 \
  && ok "default profile ($DEF) explicitly lists claude-code" \
  || bad "default profile ($DEF) does not list claude-code"

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
