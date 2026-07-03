#!/usr/bin/env bash
# base/tests/test-wireguard-component.sh — guard for SCRUM-1395 (wireguard component).
#
# The `wireguard` toolchain component mirrors `openvpn`: a components.json entry, a
# base/components/wireguard/ dir (install.sh + sb-wg-connect), and — the real wiring
# point — inclusion in the base/run.sh toolchain loop (without it the dir + JSON
# exist but the component never installs). It is SPLIT-TUNNEL only, so unlike
# sb-vpn-connect it must NOT pin net_gateway routes.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-wireguard-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_JSON="$ROOT/components.json"
RUN_SH="$ROOT/base/run.sh"
COMP_DIR="$ROOT/base/components/wireguard"
INSTALL_SH="$COMP_DIR/install.sh"
HELPER="$COMP_DIR/sb-wg-connect"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. components.json is valid JSON.
jq -e . "$COMPONENTS_JSON" >/dev/null 2>&1 \
  && ok "components.json is valid JSON" || bad "components.json is not valid JSON"

# 2. A `wireguard` entry exists with the schema-required keys + kind=toolchain.
wg_entry="$(jq -c '.components[] | select(.slug=="wireguard")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$wg_entry" ] \
  && ok "components.json has a wireguard entry" || bad "components.json missing the wireguard entry"
[ -n "$wg_entry" ] \
  && printf '%s' "$wg_entry" | jq -e 'has("slug") and has("kind") and has("title") and has("requires") and (.chip|has("label") and has("live"))' >/dev/null 2>&1 \
  && ok "wireguard entry has the required keys (slug/kind/title/requires/chip)" \
  || bad "wireguard entry missing required keys"
[ "$(printf '%s' "$wg_entry" | jq -r '.kind' 2>/dev/null)" = "toolchain" ] \
  && ok "wireguard kind is toolchain" || bad "wireguard kind is not toolchain"

# config_files contract (SCRUM-1599): wg-profile directory target.
[ "$(printf '%s' "$wg_entry" | jq -r '.config_files[0].id' 2>/dev/null)" = "wg-profile" ] \
  && ok "wireguard declares config_files[0].id = wg-profile" || bad "wireguard config_files id != wg-profile"
[ "$(printf '%s' "$wg_entry" | jq -r '.config_files[0].target_path' 2>/dev/null)" = "/etc/sidebutton/config/wireguard/" ] \
  && ok "wireguard config target_path = /etc/sidebutton/config/wireguard/" || bad "wireguard config target_path wrong"
[ "$(printf '%s' "$wg_entry" | jq -r '.config_files[0].multiple' 2>/dev/null)" = "true" ] \
  && ok "wireguard config multiple = true (named tunnels)" || bad "wireguard config multiple != true"

# 3. The component dir resolves (slug → base/components/wireguard/) with both scripts.
[ -d "$COMP_DIR" ]    && ok "base/components/wireguard/ exists"            || bad "base/components/wireguard/ missing"
[ -f "$INSTALL_SH" ]  && ok "install.sh present"                          || bad "install.sh missing"
[ -f "$HELPER" ]      && ok "sb-wg-connect present"                       || bad "sb-wg-connect missing"
[ -x "$HELPER" ]      && ok "sb-wg-connect is executable"                 || bad "sb-wg-connect is not executable"

# 4. base/run.sh toolchain loop includes wireguard (the real wiring point).
grep -qE 'for _tc in[^;]*\bwireguard\b' "$RUN_SH" \
  && ok "base/run.sh toolchain loop includes wireguard" \
  || bad "base/run.sh toolchain loop does NOT include wireguard (component would never install)"

# 5. install.sh installs wireguard-tools + the sb-wg-connect helper.
grep -q 'wireguard-tools' "$INSTALL_SH" \
  && ok "install.sh installs wireguard-tools" || bad "install.sh does not reference wireguard-tools"
grep -q '/usr/local/bin/sb-wg-connect' "$INSTALL_SH" \
  && ok "install.sh installs sb-wg-connect to /usr/local/bin" || bad "install.sh does not install sb-wg-connect"

# 6. bash -n parses both scripts (install.sh is sourced, so wrap it in a stub that
#    defines the helpers/vars it references — a bare `bash -n` is enough for syntax).
bash -n "$INSTALL_SH" 2>/dev/null && ok "install.sh parses (bash -n)" || bad "install.sh has a syntax error"
bash -n "$HELPER"     2>/dev/null && ok "sb-wg-connect parses (bash -n)" || bad "sb-wg-connect has a syntax error"

# 7. Split-tunnel invariant: the helper must NOT pin net_gateway routes (that is the
#    OpenVPN full-tunnel mechanism; WireGuard here is split-tunnel by construction).
# (Ignore comment lines: the header legitimately explains the split-tunnel
#  contrast with sb-vpn-connect; only an ACTUAL net_gateway route is a defect.)
if grep -v '^[[:space:]]*#' "$HELPER" | grep -q 'net_gateway'; then
  bad "sb-wg-connect pins net_gateway routes (should be split-tunnel only)"
else
  ok "sb-wg-connect has no net_gateway pinning (split-tunnel)"
fi

# 8. The helper brings the tunnel up via wg-quick@ and supports a remove path.
grep -q 'wg-quick@' "$HELPER" \
  && ok "sb-wg-connect uses wg-quick@<name>" || bad "sb-wg-connect does not use wg-quick@"
grep -q '= "remove"' "$HELPER" \
  && ok "sb-wg-connect supports 'remove'" || bad "sb-wg-connect missing the remove path"

# 9. The helper warns on a full-tunnel profile (out of scope for the MVP).
grep -q '0\.0\.0\.0/0' "$HELPER" \
  && ok "sb-wg-connect guards against full-tunnel AllowedIPs" || bad "sb-wg-connect missing the full-tunnel guard"

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED"
  exit 1
fi
echo "All checks passed."
