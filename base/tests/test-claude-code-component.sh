#!/usr/bin/env bash
# base/tests/test-claude-code-component.sh — guard for SCRUM-1444 (T1: catalog entries).
#
# T1 only adds the two CATALOG entries to components.json so Claude Code + the
# Router flow through provisioning and the Create-Agent wizard. The component
# install dirs (base/components/<slug>/) and base/run.sh wiring are deliberately
# OUT OF SCOPE here — they land in T2 (componentize the claude-code install) and
# T3 (the router install). So this test asserts the CATALOG SHAPE ONLY; it must
# NOT check for dirs/run.sh (that would fail until T2/T3 and is tested there).
#
# Catalog invariants pinned here:
#   - claude-code        : kind=runtime, requires=[], and NO chip (the portal
#     hardcodes a lead "Claude Code" dep-chip — getAgentChips() in the-assistant
#     profile-display.ts — so a second chip here would render a duplicate).
#   - claude-code-router : kind=runtime, requires contains claude-code,
#     chip={label:"Router", live:false}.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-claude-code-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_JSON="$ROOT/components.json"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. components.json is valid JSON (malformed JSON breaks the-assistant's sync).
jq -e . "$COMPONENTS_JSON" >/dev/null 2>&1 \
  && ok "components.json is valid JSON" || bad "components.json is not valid JSON"

# 2. claude-code entry: kind=runtime, requires=[], schema-required keys, NO chip.
cc="$(jq -c '.components[] | select(.slug=="claude-code")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$cc" ] \
  && ok "components.json has a claude-code entry" || bad "components.json missing the claude-code entry"
[ -n "$cc" ] \
  && printf '%s' "$cc" | jq -e 'has("slug") and has("kind") and has("title") and has("requires")' >/dev/null 2>&1 \
  && ok "claude-code has the schema-required keys (slug/kind/title/requires)" \
  || bad "claude-code missing schema-required keys"
[ "$(printf '%s' "$cc" | jq -r '.kind' 2>/dev/null)" = "runtime" ] \
  && ok "claude-code kind is runtime" || bad "claude-code kind is not runtime"
[ "$(printf '%s' "$cc" | jq -c '.requires' 2>/dev/null)" = "[]" ] \
  && ok "claude-code requires is empty" || bad "claude-code requires is not []"
printf '%s' "$cc" | jq -e 'has("chip")|not' >/dev/null 2>&1 \
  && ok "claude-code has NO chip (avoids duplicating the hardcoded lead chip)" \
  || bad "claude-code declares a chip (would duplicate the portal's lead Claude Code chip)"

# 3. claude-code-router entry: kind=runtime, requires ⊇ {claude-code},
#    chip={label:"Router", live:false}, schema-required keys present.
ccr="$(jq -c '.components[] | select(.slug=="claude-code-router")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$ccr" ] \
  && ok "components.json has a claude-code-router entry" || bad "components.json missing the claude-code-router entry"
[ -n "$ccr" ] \
  && printf '%s' "$ccr" | jq -e 'has("slug") and has("kind") and has("title") and has("requires") and (.chip|has("label") and has("live"))' >/dev/null 2>&1 \
  && ok "claude-code-router has the required keys (slug/kind/title/requires/chip)" \
  || bad "claude-code-router missing required keys"
[ "$(printf '%s' "$ccr" | jq -r '.kind' 2>/dev/null)" = "runtime" ] \
  && ok "claude-code-router kind is runtime" || bad "claude-code-router kind is not runtime"
printf '%s' "$ccr" | jq -e '.requires | index("claude-code")' >/dev/null 2>&1 \
  && ok "claude-code-router requires claude-code" || bad "claude-code-router does not require claude-code"
[ "$(printf '%s' "$ccr" | jq -r '.chip.label' 2>/dev/null)" = "Router" ] \
  && ok "claude-code-router chip label is Router" || bad "claude-code-router chip label is not Router"
[ "$(printf '%s' "$ccr" | jq -r '.chip.live' 2>/dev/null)" = "false" ] \
  && ok "claude-code-router chip live is false" || bad "claude-code-router chip live is not false"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
