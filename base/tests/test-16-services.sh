#!/usr/bin/env bash
# base/tests/test-16-services.sh — regression guard for the sidebutton 1.3.x
# localhost-bind incident (gostudent Hetzner fleet went "offline" 2026-06-30).
#
# sidebutton 1.3.0 changed `serve`'s default --host to 127.0.0.1 (a wide bind now
# requires SIDEBUTTON_AGENT_TOKEN). The unit runs `sidebutton serve`, so WITHOUT an
# explicit `--host 0.0.0.0` the whole cloud fleet binds localhost-only after self-
# updating to 1.3.x: the relay can no longer reach :9876 and the portal marks every
# agent "offline" (job dispatch / live-desktop / health probe all break) even though
# the server is perfectly healthy. The token is in ~/.agent-env BEFORE the unit's
# first start (base/18 swaps in the permanent sb_token; base/17 only ENABLES the
# unit; base/19b STARTS it), so the wide bind is authorized on a clean provision.
#
# Pure bash + awk (both on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-16-services.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="$SCRIPT_DIR/../16-services-prep.sh"
S17="$SCRIPT_DIR/../17-services-start.sh"
S19B="$SCRIPT_DIR/../19b-plugins.sh"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# Render the literal sidebutton.service unit the step writes (heredoc is quoted, so
# the block between the marker and its EOF is the exact unit content).
UNIT="$(awk "/cat > \/etc\/systemd\/system\/sidebutton.service <<'EOF'/{f=1;next} f&&/^EOF\$/{f=0} f" "$STEP")"

# 1. Wide bind — the fix itself.
printf '%s\n' "$UNIT" | grep -q '^ExecStart=/usr/bin/sidebutton serve --host 0\.0\.0\.0$' \
  && ok "sidebutton.service binds 0.0.0.0 (serve --host 0.0.0.0)" \
  || bad "sidebutton.service ExecStart is not 'serve --host 0.0.0.0' — 1.3.x binds localhost"

# 2. Exactly one ExecStart in the unit (no stray duplicate).
[ "$(printf '%s\n' "$UNIT" | grep -c '^ExecStart=')" = 1 ] \
  && ok "exactly one ExecStart" || bad "unexpected ExecStart count in sidebutton.service"

# 3. EnvironmentFile is the SIDEBUTTON_AGENT_TOKEN source that authorizes the wide bind.
printf '%s\n' "$UNIT" | grep -q '^EnvironmentFile=/home/agent/.agent-env$' \
  && ok "EnvironmentFile=~/.agent-env (SIDEBUTTON_AGENT_TOKEN source)" \
  || bad "EnvironmentFile missing — wide bind would be unauthorized"

# 4. Ordering invariant that makes the wide bind safe at first boot: the token is
#    present before the FIRST start. base/17 must only ENABLE the unit; base/19b
#    STARTS it (after base/18 swapped in the permanent token). A revert here would
#    start the server before the token lands and the wide bind would be refused.
grep -Eq 'systemctl[[:space:]]+start[[:space:]]+sidebutton' "$S17" \
  && bad "17-services-start.sh starts sidebutton (must only ENABLE — token not set yet)" \
  || ok "17-services-start.sh does not start sidebutton (enable-only)"
grep -Eq 'systemctl[[:space:]]+start[[:space:]]+sidebutton' "$S19B" \
  && ok "19b-plugins.sh starts sidebutton after token+secrets are written" \
  || bad "19b-plugins.sh no longer starts sidebutton (first start moved? token may be stale)"

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
