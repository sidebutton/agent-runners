#!/usr/bin/env bash
# base/tests/test-component-config.sh — guard for SCRUM-1599 (config_files catalog
# schema + default-path consumption + sb-config-place), epic SCRUM-1597.
#
# Covers, hermetically (pure bash + jq, no root / no systemd, so it stays in the
# default CI suite):
#   - schema declares config_file + config_files[] (additionalProperties:false);
#   - the 3 components declare config_files with the right target_path/multiple, and
#     the "applied manually post-provision (MVP)" prose is gone;
#   - 19f is refresh-safe (detects by helper presence, NOT has_component), is sourced
#     by run.sh + listed in refresh-manifest.txt, and its assets are in the fingerprint;
#   - sb-config-place REJECTS traversal / bad slug / accept-mismatch and confines to the
#     declared target_path (the whole trust boundary) — exercised against a temp descriptor;
#   - sb-config-reconcile applies (sha-gated), tears down removed files, and dispatches
#     service-mode — exercised with a stub helper + stub systemctl;
#   - sb-vpn-connect grew the `remove` form the reconcile teardown needs.
#
# Run: bash base/tests/test-component-config.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
SCHEMA="$ROOT/components.schema.json"
RUN="$ROOT/base/run.sh"
MANIFEST="$ROOT/base/refresh-manifest.txt"
STEP="$ROOT/base/19f-component-config.sh"
LIBREFRESH="$ROOT/base/lib-refresh.sh"
PLACE="$ROOT/base/assets/sb-config-place.sh"
RECONCILE="$ROOT/base/assets/sb-config-reconcile.sh"
VPN="$ROOT/base/components/openvpn/sb-vpn-connect"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 1. schema: config_file $def + config_files[] on component ────────────────
jq -e . "$SCHEMA" >/dev/null 2>&1 && ok "components.schema.json is valid JSON" || { bad "schema invalid"; echo TEST FAILED; exit 1; }
jq -e '.["$defs"].config_file' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema defines \$defs.config_file" || bad "schema missing \$defs.config_file"
jq -e '.["$defs"].config_file.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "config_file pins additionalProperties:false" || bad "config_file not additionalProperties:false"
jq -e '(.["$defs"].config_file.required|index("id")) and (.["$defs"].config_file.required|index("target_path"))' "$SCHEMA" >/dev/null 2>&1 \
  && ok "config_file requires id + target_path" || bad "config_file required keys wrong"
jq -e '.["$defs"].component.properties.config_files.items["$ref"]=="#/$defs/config_file"' "$SCHEMA" >/dev/null 2>&1 \
  && ok "component.config_files[] references \$defs/config_file" || bad "component.config_files ref missing"
jq -e '.["$defs"].config_file.properties.scope_default.enum==["workspace","agent"]' "$SCHEMA" >/dev/null 2>&1 \
  && ok "config_file.scope_default enum = [workspace,agent]" || bad "scope_default enum wrong"

# ── 2. schema-conformance of every declared config_files[] entry ─────────────
CF_ALLOWED="$(jq -c '[.["$defs"].config_file.properties|keys[]]' "$SCHEMA")"
CF_REQ="$(jq -c '.["$defs"].config_file.required' "$SCHEMA")"
out="$(jq -r --argjson ok "$CF_ALLOWED" --argjson req "$CF_REQ" '
  .components[] | .slug as $s | (.config_files // [])[] |
  ((($req-(.|keys))|map("\($s): missing \(.)")) + (((.|keys)-$ok)|map("\($s): unknown \(.)"))) []' "$CATALOG" 2>&1)"
[ -z "$out" ] && ok "every config_files[] entry is schema-conformant (required + no unknown keys)" \
  || bad "config_files schema drift -> $(printf '%s' "$out" | paste -sd'; ' -)"

# ── 3. the 3 components declare the right config_files ────────────────────────
check_cf() { # <slug> <id> <target_path> <multiple:true|false>
  local slug="$1" id="$2" tp="$3" mult="$4"
  local e; e="$(jq -c --arg s "$slug" '.components[]|select(.slug==$s)|.config_files[0]' "$CATALOG" 2>/dev/null)"
  [ -n "$e" ] && [ "$e" != "null" ] || { bad "$slug: no config_files[0]"; return; }
  [ "$(printf '%s' "$e" | jq -r '.id')" = "$id" ] && ok "$slug: config id=$id" || bad "$slug: id != $id"
  [ "$(printf '%s' "$e" | jq -r '.target_path')" = "$tp" ] && ok "$slug: target_path=$tp" || bad "$slug: target_path != $tp"
  [ "$(printf '%s' "$e" | jq -r '.multiple')" = "$mult" ] && ok "$slug: multiple=$mult" || bad "$slug: multiple != $mult"
}
check_cf wireguard  wg-profile   /etc/sidebutton/config/wireguard/ true
check_cf openvpn    ovpn-profile /etc/sidebutton/config/openvpn/   true
check_cf rdp-client rdp-env      /etc/sidebutton/rdp.env           false

# stale "applied manually post-provision (MVP)" prose must be gone from all three.
if jq -r '.components[]|select(.slug=="wireguard" or .slug=="openvpn")|.description' "$CATALOG" | grep -qi 'applied manually post-provision'; then
  bad "wg/openvpn description still says 'applied manually post-provision'"
else
  ok "wg/openvpn descriptions drop the 'applied manually post-provision' prose"
fi

# ── 4. 19f wiring + refresh-safety ───────────────────────────────────────────
[ -f "$STEP" ] && bash -n "$STEP" 2>/dev/null && ok "19f-component-config.sh parses (bash -n)" || bad "19f missing / syntax error"
grep -qF '19f-component-config.sh' "$RUN" && ok "run.sh sources 19f" || bad "run.sh does NOT source 19f"
# 19f must be sourced AFTER 19d and BEFORE 20-mark-installed (helpers exist, marker last)
awk '/19d-account-registry.sh/{e=NR} /19f-component-config.sh/{f=NR} /20-mark-installed.sh/{m=NR} END{exit !(e<f && f<m)}' "$RUN" \
  && ok "run.sh orders 19f after 19d, before 20-mark-installed" || bad "19f mis-ordered in run.sh"
grep -qxF '19f-component-config.sh' <(sed -e 's/[[:space:]]*#.*$//' "$MANIFEST") \
  && ok "refresh-manifest.txt lists 19f (fleet reach)" || bad "refresh-manifest.txt missing 19f"
# refresh-safe: detects by helper presence, never via has_component / AGENT_COMPONENTS
grep -q 'sb-wg-connect' "$STEP" && grep -q '\-x ' "$STEP" \
  && ok "19f detects components by installed-helper (filesystem) signal" || bad "19f missing helper-presence detection"
# Inspect CODE lines only — the header comment legitimately explains WHY has_component
# is unavailable at refresh time; only an actual use in code would be the defect.
if grep -v '^[[:space:]]*#' "$STEP" | grep -Eq 'has_component|AGENT_COMPONENTS'; then
  bad "19f uses has_component/AGENT_COMPONENTS — NOT available at refresh time"
else
  ok "19f avoids has_component/AGENT_COMPONENTS in code (refresh-safe)"
fi
# sudoers scoped to ONLY the wrapper + visudo-validated (mirrors base/08)
grep -q 'NOPASSWD: /usr/local/bin/sb-config-place' "$STEP" && grep -q 'visudo -cf' "$STEP" \
  && ok "19f installs a visudo-validated sudoers rule scoped to sb-config-place" || bad "19f sudoers rule wrong"
# the two privileged assets are in the fingerprint (else a wrapper-only fix never refreshes)
grep -q 'assets/sb-config-place.sh' "$LIBREFRESH" && grep -q 'assets/sb-config-reconcile.sh' "$LIBREFRESH" \
  && ok "lib-refresh fingerprint covers sb-config-place + sb-config-reconcile assets" \
  || bad "fingerprint does NOT cover the new assets (fleet drift on wrapper-only change)"

# ── 5. sb-vpn-connect grew the remove form the reconcile needs ───────────────
[ -f "$VPN" ] && bash -n "$VPN" 2>/dev/null && ok "sb-vpn-connect parses (bash -n)" || bad "sb-vpn-connect missing / syntax error"
grep -q '= "remove"' "$VPN" && grep -q 'openvpn-client@' "$VPN" \
  && ok "sb-vpn-connect supports 'remove' (openvpn-client@ teardown)" || bad "sb-vpn-connect missing the remove form"

# ── 6. sb-config-place: the trust boundary (hermetic rejection tests) ─────────
[ -f "$PLACE" ] && bash -n "$PLACE" 2>/dev/null && ok "sb-config-place parses (bash -n)" || bad "sb-config-place missing / syntax error"
[ -f "$RECONCILE" ] && bash -n "$RECONCILE" 2>/dev/null && ok "sb-config-reconcile parses (bash -n)" || bad "sb-config-reconcile missing / syntax error"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SB_COMPONENTS_DIR="$TMP/comp"; mkdir -p "$SB_COMPONENTS_DIR" "$TMP/wg"
cat > "$SB_COMPONENTS_DIR/wireguard.conf" <<EOF
slug=wireguard
target_path=$TMP/wg/
multiple=1
accept=.conf
consume=helper
helper_bin=$TMP/bin/stub
service=
name_max=15
EOF
mkdir -p "$TMP/rdpdir"
cat > "$SB_COMPONENTS_DIR/rdp-client.conf" <<EOF
slug=rdp-client
target_path=$TMP/rdpdir/rdp.env
multiple=0
accept=.env
consume=service
helper_bin=
service=sb-rdp
name_max=
EOF
echo staged > "$TMP/staged.conf"
# helper: assert a rejection = non-zero AND stderr matches a validation message (NOT the
# root gate — proving the check fired during validation, before any mutation).
reject() { # <desc> <args...>
  local d="$1"; shift
  local o; o="$(bash "$PLACE" "$@" 2>&1)"; local rc=$?
  if [ $rc -ne 0 ] && ! printf '%s' "$o" | grep -q 'must run as root'; then
    ok "reject: $d"
  else
    bad "reject: $d (rc=$rc out='$o')"
  fi
}
# helper: a VALID input must PASS validation and stop only at the root gate (proof the
# read-only checks accepted it — the positive control for the rejection tests).
passes_to_rootgate() { # <desc> <args...>
  local d="$1"; shift
  local o; o="$(bash "$PLACE" "$@" 2>&1)"
  printf '%s' "$o" | grep -q 'must run as root' && ok "accept-then-rootgate: $d" || bad "accept-then-rootgate: $d (out='$o')"
}
reject "traversal ../evil.conf"            wireguard  "$TMP/staged.conf" '../evil.conf'
reject "nested a/b.conf"                    wireguard  "$TMP/staged.conf" 'a/b.conf'
reject "dotdot embedded x..y"               wireguard  "$TMP/staged.conf" 'x..y.conf'
reject "newline-injected filename"          wireguard  "$TMP/staged.conf" "$(printf 'a\n.conf')"
reject "accept-mismatch .txt"               wireguard  "$TMP/staged.conf" 'bad.txt'
reject "unknown slug"                       bogus      "$TMP/staged.conf" 'x.conf'
reject "single-file wrong basename"         rdp-client "$TMP/staged.conf" 'other.env'
reject "dir --remove without filename"      --remove   wireguard
passes_to_rootgate "valid dir filename"     wireguard  "$TMP/staged.conf" 'office.conf'
passes_to_rootgate "single-file pinned name" rdp-client "$TMP/staged.conf" 'rdp.env'
passes_to_rootgate "single-file no name"    rdp-client "$TMP/staged.conf"

# ── 7. sb-config-reconcile: apply / sha-gate / teardown (stub helper) ────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/stub" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "remove" ]; then echo "REMOVE $2" >> "$STUB_LOG"; else echo "APPLY $2" >> "$STUB_LOG"; fi
EOF
chmod +x "$TMP/bin/stub"
export STUB_LOG="$TMP/calls.log" SB_CONFIG_RUN_DIR="$TMP/run"
echo A > "$TMP/wg/office.conf"; echo B > "$TMP/wg/home.conf"
: > "$STUB_LOG"; bash "$RECONCILE" wireguard >/dev/null 2>&1
grep -q 'APPLY office' "$STUB_LOG" && grep -q 'APPLY home' "$STUB_LOG" \
  && ok "reconcile applies each present file" || bad "reconcile did not apply present files"
: > "$STUB_LOG"; bash "$RECONCILE" wireguard >/dev/null 2>&1
[ ! -s "$STUB_LOG" ] && ok "reconcile is sha-gated (unchanged ⇒ no re-apply, no bounce)" || bad "reconcile re-applied unchanged files"
: > "$STUB_LOG"; rm "$TMP/wg/home.conf"; bash "$RECONCILE" wireguard >/dev/null 2>&1
grep -q 'REMOVE home' "$STUB_LOG" && ! grep -q 'REMOVE office' "$STUB_LOG" \
  && ok "reconcile tears down only the removed file" || bad "reconcile teardown wrong"
# service-mode dispatch via stub systemctl
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SVC_LOG"
EOF
chmod +x "$TMP/bin/systemctl"; export SVC_LOG="$TMP/svc.log"
echo RDP_HOST=x > "$TMP/rdpdir/rdp.env"
: > "$SVC_LOG"; PATH="$TMP/bin:$PATH" bash "$RECONCILE" rdp-client >/dev/null 2>&1
grep -q 'enable --now sb-rdp' "$SVC_LOG" && ok "reconcile service-mode: present ⇒ enable sb-rdp" || bad "service-mode present dispatch wrong"
: > "$SVC_LOG"; rm "$TMP/rdpdir/rdp.env"; PATH="$TMP/bin:$PATH" bash "$RECONCILE" rdp-client >/dev/null 2>&1
grep -q 'disable --now sb-rdp' "$SVC_LOG" && ok "reconcile service-mode: absent ⇒ disable sb-rdp" || bad "service-mode absent dispatch wrong"

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
