#!/usr/bin/env bash
# base/tests/test-android-emulator-component.sh — guard for the android-emulator component.
#
# The `android-emulator` toolchain component layers on-device runs on top of
# android-sdk: a components.json entry (requires: android-sdk), an install.sh that
# adds the emulator package + one pinned system image + the shared headless AVD,
# and the on-demand sb-avd-start / sb-avd-stop helpers. Beyond the wiring (the
# run.sh toolchain loop, ORDERED after android-sdk — it consumes its sdkmanager +
# pre-accepted licenses), this pins the contract that keeps on-device discovery
# honest: KVM is a RUN-time gate (sb-avd-start refuses without /dev/kvm; install
# never fails for it), the AVD is created as the agent user WITHOUT --force (a
# recreate would cold-boot a warmed AVD), no boot service exists (RAM stays free
# between runs), and no `yes |` license pipe (SIGPIPE 141 under run.sh's
# pipefail). Also guards the swe-android profile preset including the component.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-android-emulator-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_JSON="$ROOT/components.json"
PROFILES_JSON="$ROOT/profiles.json"
RUN_SH="$ROOT/base/run.sh"
COMP_DIR="$ROOT/base/components/android-emulator"
INSTALL_SH="$COMP_DIR/install.sh"
AVD_START="$COMP_DIR/sb-avd-start"
AVD_STOP="$COMP_DIR/sb-avd-stop"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. components.json is valid JSON with a well-formed android-emulator entry.
jq -e . "$COMPONENTS_JSON" >/dev/null 2>&1 \
  && ok "components.json is valid JSON" || bad "components.json is not valid JSON"
entry="$(jq -c '.components[] | select(.slug=="android-emulator")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$entry" ] \
  && ok "components.json has an android-emulator entry" || bad "components.json missing the android-emulator entry"
[ -n "$entry" ] \
  && printf '%s' "$entry" | jq -e 'has("slug") and has("kind") and has("title") and has("requires") and (.chip|has("label") and has("live"))' >/dev/null 2>&1 \
  && ok "android-emulator entry has the required keys (slug/kind/title/requires/chip)" \
  || bad "android-emulator entry missing required keys"
[ "$(printf '%s' "$entry" | jq -r '.kind' 2>/dev/null)" = "toolchain" ] \
  && ok "android-emulator kind is toolchain" || bad "android-emulator kind is not toolchain"
printf '%s' "$entry" | jq -e '.requires == ["android-sdk"]' >/dev/null 2>&1 \
  && ok "android-emulator requires android-sdk (sdkmanager + licenses come from it)" \
  || bad "android-emulator does not declare requires: [android-sdk]"

# 2. The component dir resolves with install.sh + both helpers, all parseable.
[ -d "$COMP_DIR" ]   && ok "base/components/android-emulator/ exists" || bad "base/components/android-emulator/ missing"
[ -f "$INSTALL_SH" ] && ok "install.sh present"                       || bad "install.sh missing"
bash -n "$INSTALL_SH" 2>/dev/null \
  && ok "install.sh parses (bash -n)" || bad "install.sh does not parse"
[ -f "$AVD_START" ] && ok "sb-avd-start helper present" || bad "sb-avd-start helper missing"
[ -f "$AVD_STOP" ]  && ok "sb-avd-stop helper present"  || bad "sb-avd-stop helper missing"
bash -n "$AVD_START" 2>/dev/null \
  && ok "sb-avd-start parses (bash -n)" || bad "sb-avd-start does not parse"
bash -n "$AVD_STOP" 2>/dev/null \
  && ok "sb-avd-stop parses (bash -n)" || bad "sb-avd-stop does not parse"

# 3. base/run.sh toolchain loop includes android-emulator AFTER android-sdk.
grep -qE 'for _tc in[^;]*\bandroid-emulator\b' "$RUN_SH" \
  && ok "base/run.sh toolchain loop includes android-emulator" \
  || bad "base/run.sh toolchain loop does NOT include android-emulator (component would never install)"
grep -qE 'for _tc in[^;]*\bandroid-sdk\b[^;]*\bandroid-emulator\b' "$RUN_SH" \
  && ok "toolchain loop orders android-emulator after android-sdk" \
  || bad "android-emulator is not ordered after android-sdk in the toolchain loop"

# 4. Install contract.
grep -qE 'ANDROID_EMULATOR_IMAGE="system-images;[^"]+"' "$INSTALL_SH" \
  && ok "system image is pinned (no floating image)" || bad "system image is not pinned"
grep -q '"emulator"' "$INSTALL_SH" \
  && ok "install.sh installs the emulator package" || bad "install.sh never installs the emulator package"
grep -qE '^[[:space:]]*yes[[:space:]]*\|' "$INSTALL_SH" \
  && bad "pipe uses \`yes |\` — SIGPIPE 141 under run.sh's pipefail makes every success a false WARN" \
  || ok "no \`yes |\` pipe (no SIGPIPE false-WARN under pipefail)"
grep -q 'usermod -aG kvm' "$INSTALL_SH" \
  && ok "agent user is added to the kvm group" || bad "agent user never joins the kvm group"
grep -q 'create avd' "$INSTALL_SH" \
  && ok "install.sh creates the shared AVD" || bad "install.sh never creates an AVD"
grep -q 'runuser -u "\$AGENT_USER"' "$INSTALL_SH" \
  && ok "AVD is created as the agent user (emulator writes locks/snapshots into ~/.android)" \
  || bad "AVD is not created as the agent user"
grep -vE '^[[:space:]]*#' "$INSTALL_SH" | grep -q -- '--force' \
  && bad "avdmanager uses --force — a recreate cold-boots a warmed AVD" \
  || ok "no --force on AVD creation (existing AVD is kept)"
grep -qE '\.service' "$INSTALL_SH" \
  && bad "install.sh wires a service — the emulator must boot on demand only (RAM)" \
  || ok "no boot service (emulator RAM stays free between runs)"
grep -q 'install -m 0755 .*sb-avd-start' "$INSTALL_SH" \
  && ok "sb-avd-start is installed to /usr/local/bin" || bad "sb-avd-start is never installed"
grep -q 'install -m 0755 .*sb-avd-stop' "$INSTALL_SH" \
  && ok "sb-avd-stop is installed to /usr/local/bin" || bad "sb-avd-stop is never installed"

# 5. Run-time contract: KVM is gated in the helper, not the installer.
grep -q '/dev/kvm' "$AVD_START" \
  && ok "sb-avd-start gates on /dev/kvm" || bad "sb-avd-start never checks /dev/kvm"
grep -q 'sys.boot_completed' "$AVD_START" \
  && ok "sb-avd-start waits for sys.boot_completed" || bad "sb-avd-start does not wait for full boot"
grep -q -- '-no-window' "$AVD_START" \
  && ok "sb-avd-start boots headless (-no-window)" || bad "sb-avd-start is not headless"
grep -vE '^[[:space:]]*#' "$AVD_START" | grep -q 'wait-for-device' \
  && bad "sb-avd-start uses adb wait-for-device — hangs forever when the emulator dies pre-registration" \
  || ok "sb-avd-start avoids adb wait-for-device (deadline-bounded polling instead)"
grep -q 'BOOT_TIMEOUT' "$AVD_START" \
  && ok "sb-avd-start waits are deadline-bounded (SB_AVD_BOOT_TIMEOUT)" \
  || bad "sb-avd-start has no boot timeout"
grep -q 'android-emulator requires android-sdk' "$ROOT/base/components.sh" \
  && ok "components.sh defensively enables android-sdk for android-emulator (non-wizard callers)" \
  || bad "components.sh does not enforce android-emulator's android-sdk prerequisite"
grep -qE 'exit 1' "$INSTALL_SH" \
  && bad "install.sh hard-exits — component installs must WARN-and-continue" \
  || ok "install.sh never hard-exits (WARN-and-continue contract)"

# 6. profiles.json: swe-android includes the component (superset shape is owned
#    by test-android-sdk-component.sh — asserted there against full-stack).
jq -e '.profiles[] | select(.slug=="swe-android") | .components | index("android-emulator")' "$PROFILES_JSON" >/dev/null 2>&1 \
  && ok "swe-android preset includes android-emulator" || bad "swe-android preset missing android-emulator"
jq -e '.profiles[] | select(.slug=="swe-android") | .components | (index("android-sdk") < index("android-emulator"))' "$PROFILES_JSON" >/dev/null 2>&1 \
  && ok "swe-android lists android-sdk before android-emulator" \
  || bad "swe-android lists android-emulator before its android-sdk prerequisite"

echo
if [ "$fail" = 0 ]; then echo "TEST PASSED"; else echo "TEST FAILED"; exit 1; fi
