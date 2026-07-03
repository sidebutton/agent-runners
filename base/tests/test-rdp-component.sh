#!/usr/bin/env bash
# base/tests/test-rdp-component.sh — regression guard for SCRUM-1396.
#
# The `rdp-client` component must (AC1) be a schema-shaped catalog entry that
# resolves to base/components/rdp-client/ AND be sourced by run.sh's toolchain
# loop (the silent-failure trap: dir+JSON without the loop edit => never installs),
# and (AC2/AC3) ship an sb-rdp-connect helper that pins xfreerdp geometry so the
# window dimensions stay constant across reconnects.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-rdp-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
RUN="$ROOT/base/run.sh"
DIR="$ROOT/base/components/rdp-client"
INSTALL="$DIR/install.sh"
HELPER="$DIR/sb-rdp-connect"
fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── AC1: catalog entry, schema-shaped ───────────────────────────────────────
jq -e . "$CATALOG" >/dev/null 2>&1 && ok "components.json is valid JSON" \
  || bad "components.json is not valid JSON"

ENTRY='.components[] | select(.slug=="rdp-client")'
[ "$(jq -r "$ENTRY | .slug" "$CATALOG")" = "rdp-client" ] \
  && ok "rdp-client entry present" || bad "rdp-client entry missing"
[ "$(jq -r "$ENTRY | .kind" "$CATALOG")" = "toolchain" ] \
  && ok "kind = toolchain" || bad "kind != toolchain"
[ "$(jq -r "$ENTRY | .requires | length" "$CATALOG")" = "0" ] \
  && ok "requires = []" || bad "requires not empty"
[ "$(jq -r "$ENTRY | .chip.label" "$CATALOG")" = "RDP" ] \
  && ok "chip.label = RDP" || bad "chip.label != RDP"
[ "$(jq -r "$ENTRY | .chip.live" "$CATALOG")" = "false" ] \
  && ok "chip.live = false" || bad "chip.live != false"
[ -n "$(jq -r "$ENTRY | .title // empty" "$CATALOG")" ] \
  && ok "title present" || bad "title missing"
# slug satisfies the schema pattern ^[a-z0-9][a-z0-9-]*$
jq -r '.components[].slug' "$CATALOG" | grep -qE '^rdp-client$' \
  && ok "slug matches schema pattern" || bad "slug fails schema pattern"
# chip carries no disallowed processKey (RDP is not in the schema's processKey enum)
[ "$(jq -r "$ENTRY | .chip.processKey // \"none\"" "$CATALOG")" = "none" ] \
  && ok "chip has no processKey (live:false static chip)" || bad "chip.processKey set unexpectedly"

# ── config_files contract (SCRUM-1599): rdp-env single-file target ───────────
[ "$(jq -r "$ENTRY | .config_files[0].id" "$CATALOG")" = "rdp-env" ] \
  && ok "declares config_files[0].id = rdp-env" || bad "config_files id != rdp-env"
[ "$(jq -r "$ENTRY | .config_files[0].target_path" "$CATALOG")" = "/etc/sidebutton/rdp.env" ] \
  && ok "config target_path = /etc/sidebutton/rdp.env" || bad "config target_path wrong"
[ "$(jq -r "$ENTRY | .config_files[0].multiple" "$CATALOG")" = "false" ] \
  && ok "config multiple = false (single file)" || bad "config multiple != false"

# ── AC1: wiring — run.sh toolchain loop sources it (else it silently never installs)
grep -Eq 'for _tc in .*\brdp-client\b' "$RUN" \
  && ok "run.sh toolchain loop includes rdp-client" \
  || bad "run.sh toolchain loop MISSING rdp-client (component would never install)"

# ── component files exist + parse ────────────────────────────────────────────
[ -f "$INSTALL" ] && ok "install.sh present" || bad "install.sh missing"
[ -f "$HELPER" ]  && ok "sb-rdp-connect present" || bad "sb-rdp-connect missing"
[ -x "$HELPER" ]  && ok "sb-rdp-connect is executable" || bad "sb-rdp-connect not executable"
bash -n "$INSTALL" 2>/dev/null && ok "install.sh: bash -n clean" || bad "install.sh: bash -n failed"
bash -n "$HELPER"  2>/dev/null && ok "sb-rdp-connect: bash -n clean" || bad "sb-rdp-connect: bash -n failed"

# ── install.sh installs FreeRDP + writes the on-:10 service ──────────────────
grep -q 'freerdp2-x11' "$INSTALL" && ok "install.sh installs freerdp2-x11" || bad "install.sh missing freerdp2-x11"
grep -q '/etc/systemd/system/sb-rdp.service' "$INSTALL" && ok "install.sh writes sb-rdp.service" || bad "install.sh missing sb-rdp.service"
grep -q 'User=agent' "$INSTALL" && grep -q 'DISPLAY=:10' "$INSTALL" \
  && ok "sb-rdp.service runs as agent on :10" || bad "sb-rdp.service not User=agent/DISPLAY=:10"
grep -q 'install -m 0755' "$INSTALL" \
  && ok "helper installed 0755 (agent-executable under User=agent unit)" \
  || bad "helper not installed 0755 (User=agent could not exec it)"

# ── AC3: helper PINS geometry (and avoids the rescaling anti-flags) ──────────
# Anti-flag checks run on CODE lines only (the header comment legitimately names
# /f and /smart-sizing to explain they are deliberately avoided).
CODE="$(grep -v '^[[:space:]]*#' "$HELPER")"
for flag in '/scale:100' '-dynamic-resolution' '/size:' '/cert:ignore' 'auto-reconnect'; do
  grep -qF -- "$flag" "$HELPER" && ok "helper sets ${flag}" || bad "helper missing ${flag}"
done
printf '%s\n' "$CODE" | grep -q '/smart-sizing' && bad "helper uses /smart-sizing (would rescale → breaks AC3)" \
  || ok "helper avoids /smart-sizing"
printf '%s\n' "$CODE" | grep -Eq '(^|[[:space:]])/f([[:space:]]|$)' && bad "helper uses /f fullscreen (would rescale → breaks AC3)" \
  || ok "helper avoids /f fullscreen"
# reads creds from the out-of-band env file, idle-waits when absent (no Restart thrash)
grep -q '/etc/sidebutton/rdp.env' "$HELPER" && ok "helper reads /etc/sidebutton/rdp.env" || bad "helper missing rdp.env path"
grep -q 'sleep' "$HELPER" && ok "helper idle-waits (no tight loop under Restart=always)" || bad "helper has no idle/sleep guard"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
