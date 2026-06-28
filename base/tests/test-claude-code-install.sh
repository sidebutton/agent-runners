#!/usr/bin/env bash
# base/tests/test-claude-code-install.sh — guard for SCRUM-1445 (T2: componentize
# the Claude Code install).
#
# T1's test-claude-code-component.sh asserts the components.json CATALOG SHAPE only
# (kind=runtime, requires=[], no chip) and is deliberately blind to the install dir
# / run.sh wiring. THIS test owns the T2 wiring: the former base/07-claude-code.sh
# is moved verbatim into base/components/claude-code/install.sh, gated behind a
# DEFAULT-ON INSTALL_CLAUDE_CODE flag (base/components.sh) and sourced from
# base/run.sh at the same position.
#
# Acceptance (mirrors the ticket):
#   AC1 — default provision (AGENT_COMPONENTS unset/empty) → INSTALL_CLAUDE_CODE=1
#   AC2 — a set containing `claude-code`                   → INSTALL_CLAUDE_CODE=1
#   AC3 — a non-empty set WITHOUT `claude-code`            → INSTALL_CLAUDE_CODE=0
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-claude-code-install.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
RUN_SH="$ROOT/base/run.sh"
COMPONENTS_SH="$ROOT/base/components.sh"
COMP_DIR="$ROOT/base/components/claude-code"
INSTALL_SH="$COMP_DIR/install.sh"
OLD_STEP="$ROOT/base/07-claude-code.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. The component dir + install.sh resolve (slug → base/components/claude-code/).
[ -d "$COMP_DIR" ]   && ok "base/components/claude-code/ exists"   || bad "base/components/claude-code/ missing"
[ -f "$INSTALL_SH" ] && ok "install.sh present"                    || bad "install.sh missing"

# 2. The former base step was MOVED, not left behind (no double install / stale ref).
[ ! -f "$OLD_STEP" ] \
  && ok "base/07-claude-code.sh removed (moved into the component)" \
  || bad "base/07-claude-code.sh still exists (should have been moved)"

# 3. install.sh installs the Claude Code CLI byte-identically (the parity-critical
#    npm line is preserved from the old step).
grep -q '@anthropic-ai/claude-code' "$INSTALL_SH" \
  && ok "install.sh installs @anthropic-ai/claude-code" || bad "install.sh does not reference @anthropic-ai/claude-code"
grep -q 'command -v claude' "$INSTALL_SH" \
  && ok "install.sh keeps the idempotent 'command -v claude' guard" || bad "install.sh lost the idempotency guard"

# 4. install.sh parses (it is sourced, so bash -n is enough for syntax).
bash -n "$INSTALL_SH" 2>/dev/null && ok "install.sh parses (bash -n)" || bad "install.sh has a syntax error"

# 5. run.sh sources the component GATED on INSTALL_CLAUDE_CODE and no longer
#    references the old step file.
grep -q 'components/claude-code/install.sh' "$RUN_SH" \
  && ok "run.sh sources components/claude-code/install.sh" || bad "run.sh does not source the claude-code component"
grep -q 'INSTALL_CLAUDE_CODE' "$RUN_SH" \
  && ok "run.sh gates the source on INSTALL_CLAUDE_CODE" || bad "run.sh source is not gated on INSTALL_CLAUDE_CODE"
grep -q '07-claude-code.sh' "$RUN_SH" \
  && bad "run.sh still references 07-claude-code.sh" || ok "run.sh no longer references 07-claude-code.sh"

# 6. Position invariant: claude-code installs BEFORE the Claude-config steps
#    (08-sidebutton, 14-claude-stop-hook) that assume `claude` exists.
cc_line="$(grep -n 'components/claude-code/install.sh' "$RUN_SH" | head -n1 | cut -d: -f1)"
hook_line="$(grep -n '14-claude-stop-hook.sh' "$RUN_SH" | head -n1 | cut -d: -f1)"
sb_line="$(grep -n '08-sidebutton.sh' "$RUN_SH" | head -n1 | cut -d: -f1)"
if [ -n "$cc_line" ] && [ -n "$hook_line" ] && [ -n "$sb_line" ] \
   && [ "$cc_line" -lt "$sb_line" ] && [ "$cc_line" -lt "$hook_line" ]; then
  ok "run.sh sources claude-code before 08-sidebutton and 14-claude-stop-hook"
else
  bad "run.sh sources claude-code at the wrong position (must precede 08/14)"
fi

# 7. base/components.sh derives + logs the INSTALL_CLAUDE_CODE gate.
grep -q 'INSTALL_CLAUDE_CODE' "$COMPONENTS_SH" \
  && ok "components.sh derives INSTALL_CLAUDE_CODE" || bad "components.sh does not derive INSTALL_CLAUDE_CODE"
grep -q 'claude-code=' "$COMPONENTS_SH" \
  && ok "components.sh logs the claude-code gate in the summary line" || bad "components.sh gate summary omits claude-code"

# 8. Runtime gate parity (AC1/AC2/AC3): source components.sh (with a stubbed log)
#    under each input in an isolated subshell and read INSTALL_CLAUDE_CODE.
gate() {
  ( log() { :; }
    if [ "$1" = "__unset__" ]; then unset AGENT_COMPONENTS; else export AGENT_COMPONENTS="$1"; fi
    # shellcheck disable=SC1090
    . "$COMPONENTS_SH" >/dev/null 2>&1
    printf '%s' "${INSTALL_CLAUDE_CODE:-unset}" )
}

[ "$(gate __unset__)" = 1 ]                     && ok "AC1: AGENT_COMPONENTS unset → INSTALL_CLAUDE_CODE=1" || bad "AC1: unset did not yield 1"
[ "$(gate "")" = 1 ]                            && ok "AC1: AGENT_COMPONENTS empty → INSTALL_CLAUDE_CODE=1" || bad "AC1: empty did not yield 1"
[ "$(gate "   ")" = 1 ]                          && ok "AC1: whitespace-only set → INSTALL_CLAUDE_CODE=1"    || bad "AC1: whitespace-only did not yield 1"
[ "$(gate "claude-code")" = 1 ]                 && ok "AC2: set=claude-code → INSTALL_CLAUDE_CODE=1"        || bad "AC2: claude-code set did not yield 1"
[ "$(gate "chrome,claude-code")" = 1 ]          && ok "AC2: comma set containing claude-code → 1"          || bad "AC2: comma set containing claude-code did not yield 1"
[ "$(gate "chrome sidebutton-server")" = 0 ]    && ok "AC3: set without claude-code → INSTALL_CLAUDE_CODE=0" || bad "AC3: space set without claude-code did not yield 0"
[ "$(gate "chrome,sidebutton-server")" = 0 ]    && ok "AC3: comma set without claude-code → 0"             || bad "AC3: comma set without claude-code did not yield 0"

# 9. -e safety: the new gate block must not abort provisioning under run.sh's
#    `set -euo pipefail` (a bare failing command here would brick every install).
if ( set -euo pipefail; log() { :; }; export AGENT_COMPONENTS="chrome sidebutton-server"; . "$COMPONENTS_SH" ) >/dev/null 2>&1; then
  ok "components.sh runs clean under set -euo pipefail (AC3 set)"
else
  bad "components.sh aborts under set -euo pipefail"
fi
if ( set -euo pipefail; log() { :; }; unset AGENT_COMPONENTS; . "$COMPONENTS_SH" ) >/dev/null 2>&1; then
  ok "components.sh runs clean under set -euo pipefail (empty set)"
else
  bad "components.sh aborts under set -euo pipefail (empty set)"
fi

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
