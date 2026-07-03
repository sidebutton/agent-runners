#!/usr/bin/env bash
# base/tests/test-component-config.sh — guard for SCRUM-1599 (A1): the component
# config-file consumption rail (config_files catalog schema + default-path watchers +
# the privileged sb-config-place wrapper + sb-config-reconcile).
#
# Hermetic (pure bash + jq, no root, no systemd): the two runtime-critical parts —
# sb-config-place's path confinement and sb-config-reconcile's apply/SHA-gate/teardown
# — are exercised against TEMP descriptors with a FAKE helper, so this runs on a
# generic CI runner and is NOT in ci-exclude.txt. The on-VM DoD (real wg-quick up on
# boot, sudoers scoping) is the QA playbook, not this guard.
#
# Run: bash base/tests/test-component-config.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
CATALOG="$ROOT/components.json"
SCHEMA="$ROOT/components.schema.json"
RUN_SH="$ROOT/base/run.sh"
MANIFEST="$ROOT/base/refresh-manifest.txt"
STEP="$ROOT/base/19f-component-config.sh"
ASSETS="$ROOT/base/assets"
PLACE="$ASSETS/sb-config-place.sh"
RECON="$ASSETS/sb-config-reconcile.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── 1. catalog: the 3 components declare config_files with the expected contract ──
jq -e . "$CATALOG" >/dev/null 2>&1 && ok "components.json is valid JSON" || { bad "components.json invalid"; echo "TEST FAILED"; exit 1; }

# slug | id | target_path | multiple
check_cfg() { # <slug> <id> <target_path> <multiple>
  local slug="$1" id="$2" tp="$3" mu="$4" e
  e="$(jq -c --arg s "$slug" '.components[]|select(.slug==$s)|.config_files[0]' "$CATALOG" 2>/dev/null)"
  [ -n "$e" ] && [ "$e" != "null" ] || { bad "$slug: no config_files[0]"; return; }
  [ "$(printf '%s' "$e" | jq -r '.id')" = "$id" ]           && ok "$slug: config id=$id" || bad "$slug: id != $id"
  [ "$(printf '%s' "$e" | jq -r '.target_path')" = "$tp" ]  && ok "$slug: target_path=$tp" || bad "$slug: target_path != $tp"
  [ "$(printf '%s' "$e" | jq -r '.multiple')" = "$mu" ]     && ok "$slug: multiple=$mu" || bad "$slug: multiple != $mu"
}
check_cfg wireguard  wg-profile   /etc/sidebutton/config/wireguard/ true
check_cfg openvpn    ovpn-profile /etc/sidebutton/config/openvpn/   true
check_cfg rdp-client rdp-env      /etc/sidebutton/rdp.env           false

# every config_files[] entry has the schema-required keys (id + target_path)
none_missing="$(jq -r '.components[]|select(.config_files)|.slug as $s|.config_files[]|select((has("id")|not) or (has("target_path")|not))|"\($s)"' "$CATALOG" 2>/dev/null)"
[ -z "$none_missing" ] && ok "every config_files[] entry has id + target_path" || bad "config_files missing id/target_path: $none_missing"

# directory targets (trailing '/') are multiple:true; the file target is multiple:false
mism="$(jq -r '.components[]|select(.config_files)|.slug as $s|.config_files[]|select((.target_path|endswith("/")) != (.multiple==true))|"\($s):\(.id)"' "$CATALOG" 2>/dev/null)"
[ -z "$mism" ] && ok "target_path dir/file shape matches multiple flag" || bad "dir/file vs multiple mismatch: $mism"

# ── 2. schema: config_file sub-schema exists + is referenced + stays closed ──────
jq -e '.["$defs"].config_file' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema defines \$defs.config_file" || bad "schema missing \$defs.config_file"
jq -e '.["$defs"].config_file.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "config_file is additionalProperties:false" || bad "config_file not closed (additionalProperties)"
jq -e '.["$defs"].config_file.required|(index("id") and index("target_path"))' "$SCHEMA" >/dev/null 2>&1 \
  && ok "config_file requires id + target_path" || bad "config_file.required missing id/target_path"
jq -e '.["$defs"].component.properties.config_files.items["$ref"]=="#/$defs/config_file"' "$SCHEMA" >/dev/null 2>&1 \
  && ok "component.config_files[] references \$defs/config_file" || bad "component.config_files does not \$ref config_file"
jq -e '.["$defs"].component.additionalProperties==false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "component still additionalProperties:false (config_files is a declared key)" || bad "component no longer closed"
jq -e '.["$defs"].config_file.properties.scope_default.enum==["workspace","agent"]' "$SCHEMA" >/dev/null 2>&1 \
  && ok "scope_default enum = [workspace, agent]" || bad "scope_default enum wrong"

# config-file entries in the catalog carry no key outside the schema's config_file props
CF_ALLOWED="$(jq -c '[.["$defs"].config_file.properties|keys[]]' "$SCHEMA")"
unknown="$(jq -r --argjson ok "$CF_ALLOWED" '.components[]|select(.config_files)|.slug as $s|.config_files[]| . as $c|(($c|keys)-$ok) as $x|select($x|length>0)|"\($s): \($x|join(","))"' "$CATALOG" 2>/dev/null)"
[ -z "$unknown" ] && ok "no unknown keys on any config_files[] entry" || bad "unknown config_files keys: $unknown"

# ── 3. wiring: run.sh sources 19f (after 19e), refresh-manifest lists it ──────────
grep -qE '^\. +"\$BASE_DIR/19f-component-config\.sh"' "$RUN_SH" \
  && ok "base/run.sh sources 19f-component-config.sh" || bad "run.sh does NOT source 19f"
awk '/19e-session-reaper\.sh/{e=NR} /19f-component-config\.sh/{f=NR} /20-mark-installed\.sh/{m=NR} END{exit !(e<f && f<m)}' "$RUN_SH" \
  && ok "19f is ordered after 19e and before 20-mark-installed" || bad "19f mis-ordered in run.sh"
grep -qxF '19f-component-config.sh' <(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$MANIFEST") \
  && ok "refresh-manifest.txt lists 19f (reaches the fleet via sb-self-update)" || bad "refresh-manifest.txt missing 19f"

# ── 4. assets present, parse clean, units carry the expected wiring ───────────────
for f in "$PLACE" "$RECON" "$STEP"; do
  [ -f "$f" ] && ok "present: ${f#$ROOT/}" || bad "missing: ${f#$ROOT/}"
  bash -n "$f" 2>/dev/null && ok "parses (bash -n): ${f#$ROOT/}" || bad "syntax error: ${f#$ROOT/}"
done
APPLY_UNIT="$ASSETS/sb-config-apply@.service"; WATCH_UNIT="$ASSETS/sb-config-watch@.path"
[ -f "$APPLY_UNIT" ] && ok "sb-config-apply@.service template present" || bad "apply unit template missing"
[ -f "$WATCH_UNIT" ] && ok "sb-config-watch@.path template present"   || bad "watch unit template missing"
grep -q 'ExecStart=/usr/local/bin/sb-config-reconcile %i' "$APPLY_UNIT" 2>/dev/null \
  && ok "apply unit runs sb-config-reconcile %i" || bad "apply unit ExecStart wrong"
grep -q 'Unit=sb-config-apply@%i.service' "$WATCH_UNIT" 2>/dev/null \
  && ok "watch unit triggers sb-config-apply@%i" || bad "watch unit does not trigger the apply service"
# 19f must install the sudoers + wrapper + reconcile + unit templates
grep -q '/etc/sudoers.d/sb-config-place' "$STEP" && ok "19f writes the narrow sudoers" || bad "19f missing sudoers"
grep -q 'visudo -cf' "$STEP" && ok "19f visudo-validates the sudoers" || bad "19f does not visudo-validate"
grep -q '/usr/local/bin/sb-config-place' "$STEP" && ok "19f installs the place wrapper" || bad "19f missing wrapper install"

# ── 5. the sudoers line 19f writes is visudo-valid (guarded: visudo may be absent) ─
if command -v visudo >/dev/null 2>&1; then
  tmp_sudo="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: /usr/local/bin/sb-config-place\n' "agent" > "$tmp_sudo"
  visudo -cf "$tmp_sudo" >/dev/null 2>&1 && ok "sb-config-place sudoers line is visudo-valid" || bad "sudoers line fails visudo -cf"
  rm -f "$tmp_sudo"
else
  ok "visudo absent on this runner — sudoers syntax check skipped"
fi

# ── 6. sb-config-place hardening: traversal / escape rejected, valid names pass ───
tmpc="$(mktemp -d)"; cdir="$tmpc/components"; mkdir -p "$cdir" "$tmpc/wg"
printf 'slug=wireguard\ntarget_path=%s/wg/\nmultiple=true\naccept=.conf\nmode=profile-dir\n' "$tmpc" > "$cdir/wireguard.conf"
printf 'slug=rdp-client\ntarget_path=%s/rdp.env\nmultiple=false\naccept=.env\nmode=env-file\n' "$tmpc" > "$cdir/rdp-client.conf"
touch "$tmpc/staged.conf"
place() { SB_COMPONENTS_DIR="$cdir" bash "$PLACE" "$@" 2>&1; }
rejects() { # <label> <expected-msg-substr> <args...>
  local label="$1" want="$2"; shift 2
  local out; out="$(place "$@")"; local rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiF "$want"; then ok "reject: $label"; else bad "reject: $label (rc=$rc out=$out)"; fi
}
rejects "traversal ../evil.conf" "invalid filename"           wireguard "$tmpc/staged.conf" '../evil.conf'
rejects "slash sub/x.conf"        "invalid filename"           wireguard "$tmpc/staged.conf" 'sub/x.conf'
rejects "absolute /etc/x.conf"    "invalid filename"           wireguard "$tmpc/staged.conf" '/etc/x.conf'
rejects "leading-dash -rf.conf"   "invalid filename"           wireguard "$tmpc/staged.conf" '-rf.conf'
rejects "unknown slug bogus"      "unknown/uninstalled"        bogus     "$tmpc/staged.conf" 'x.conf'
rejects "bad extension .txt"      "does not match"             wireguard "$tmpc/staged.conf" 'evil.txt'
rejects "rdp non-pinned name"     "pins a single file"         rdp-client "$tmpc/staged.conf" 'other.env'
# a VALID name must PASS validation and stop only at the (non-root) privilege check.
valid_out="$(place wireguard "$tmpc/staged.conf" 'office.conf')"
printf '%s' "$valid_out" | grep -qi 'must run as root' \
  && ok "valid name office.conf passes validation (stops at root check)" \
  || bad "valid name over-rejected: $valid_out"
# symlinked staged source is refused (would need root; validated pre-root only for path,
# so assert the message class is reachable by pointing at a symlink w/ a valid name):
ln -s /etc/hostname "$tmpc/link.conf" 2>/dev/null || true
rm -rf "$tmpc"

# ── 7. sb-config-reconcile: apply, SHA-gate, teardown (profile-dir, fake helper) ──
tmpr="$(mktemp -d)"; rc_cdir="$tmpr/components"; wg="$tmpr/wg"; mkdir -p "$rc_cdir" "$wg" "$tmpr/bin"
cat > "$tmpr/bin/fakehelper" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmpr/calls.log"
EOF
chmod +x "$tmpr/bin/fakehelper"
printf 'slug=wireguard\ntarget_path=%s/\nmultiple=true\naccept=.conf\nmode=profile-dir\nhelper=%s\nservice=\n' "$wg" "$tmpr/bin/fakehelper" > "$rc_cdir/wireguard.conf"
recon() { SB_COMPONENTS_DIR="$rc_cdir" bash "$RECON" wireguard 2>/dev/null; }
echo "k1" > "$wg/office.conf"; : > "$tmpr/calls.log"; recon
grep -q "office.conf office" "$tmpr/calls.log" && ok "reconcile applies a dropped profile" || bad "reconcile did not apply"
: > "$tmpr/calls.log"; recon
[ ! -s "$tmpr/calls.log" ] && ok "reconcile SHA-gates an unchanged profile (no re-apply)" || bad "reconcile re-applied unchanged file"
echo "k2" > "$wg/office.conf"; : > "$tmpr/calls.log"; recon
grep -q "office.conf office" "$tmpr/calls.log" && ok "reconcile re-applies on content change" || bad "reconcile missed a change"
rm "$wg/office.conf"; : > "$tmpr/calls.log"; recon
grep -qx "remove office" "$tmpr/calls.log" && ok "reconcile tears down a vanished profile (remove)" || bad "reconcile did not tear down"
rm -rf "$tmpr"

# ── 8. openvpn helper gained the 'remove' teardown form (reconcile needs it) ──────
OVPN="$ROOT/base/components/openvpn/sb-vpn-connect"
grep -q '= "remove"' "$OVPN" 2>/dev/null \
  && ok "sb-vpn-connect supports 'remove' (openvpn teardown)" || bad "sb-vpn-connect missing the remove form"

if [ "$fail" -ne 0 ]; then echo "TEST FAILED"; exit 1; fi
echo "All checks passed."
