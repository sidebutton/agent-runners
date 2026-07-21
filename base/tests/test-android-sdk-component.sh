#!/usr/bin/env bash
# base/tests/test-android-sdk-component.sh — guard for the android-sdk component.
#
# The `android-sdk` toolchain component follows the dotnet9 pattern: a
# components.json entry, base/components/android-sdk/install.sh, and — the real
# wiring point — inclusion in the base/run.sh toolchain loop (without it the dir +
# JSON exist but the component never installs). Beyond the wiring, this pins the
# install contract that makes UNATTENDED Android builds work: license acceptance
# at provision (AGP's build-time self-serve download path depends on it), a
# PINNED cmdline-tools build (no floating latest), ANDROID_HOME in
# /etc/environment, the SDK tree handed to the agent user, and NO emulator/AVD
# (cloud agents have no KVM guarantee — the component promises headless
# build/lint/unit-test parity only). Also guards the swe-android profile preset.
#
# Pure bash + jq (both present on the runner) — no bats/CI dependency.
# Run: bash base/tests/test-android-sdk-component.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
COMPONENTS_JSON="$ROOT/components.json"
PROFILES_JSON="$ROOT/profiles.json"
RUN_SH="$ROOT/base/run.sh"
COMP_DIR="$ROOT/base/components/android-sdk"
INSTALL_SH="$COMP_DIR/install.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. components.json is valid JSON.
jq -e . "$COMPONENTS_JSON" >/dev/null 2>&1 \
  && ok "components.json is valid JSON" || bad "components.json is not valid JSON"

# 2. An `android-sdk` entry exists with the schema-required keys + kind=toolchain.
entry="$(jq -c '.components[] | select(.slug=="android-sdk")' "$COMPONENTS_JSON" 2>/dev/null)"
[ -n "$entry" ] \
  && ok "components.json has an android-sdk entry" || bad "components.json missing the android-sdk entry"
[ -n "$entry" ] \
  && printf '%s' "$entry" | jq -e 'has("slug") and has("kind") and has("title") and has("requires") and (.chip|has("label") and has("live"))' >/dev/null 2>&1 \
  && ok "android-sdk entry has the required keys (slug/kind/title/requires/chip)" \
  || bad "android-sdk entry missing required keys"
[ "$(printf '%s' "$entry" | jq -r '.kind' 2>/dev/null)" = "toolchain" ] \
  && ok "android-sdk kind is toolchain" || bad "android-sdk kind is not toolchain"

# 3. The component dir resolves (slug → base/components/android-sdk/) with install.sh.
[ -d "$COMP_DIR" ]   && ok "base/components/android-sdk/ exists" || bad "base/components/android-sdk/ missing"
[ -f "$INSTALL_SH" ] && ok "install.sh present"                  || bad "install.sh missing"
bash -n "$INSTALL_SH" 2>/dev/null \
  && ok "install.sh parses (bash -n)" || bad "install.sh does not parse"

# 4. base/run.sh toolchain loop includes android-sdk (the real wiring point).
grep -qE 'for _tc in[^;]*\bandroid-sdk\b' "$RUN_SH" \
  && ok "base/run.sh toolchain loop includes android-sdk" \
  || bad "base/run.sh toolchain loop does NOT include android-sdk (component would never install)"

# 5. Install contract: the invariants unattended Gradle builds depend on.
grep -q 'openjdk-17' "$INSTALL_SH" \
  && ok "install.sh installs OpenJDK 17 (Gradle 9 / AGP floor)" || bad "install.sh does not install OpenJDK 17"
grep -qE 'ANDROID_CMDLINE_TOOLS_BUILD=[0-9]+' "$INSTALL_SH" \
  && ok "cmdline-tools build is pinned (no floating latest)" || bad "cmdline-tools build is not pinned"
grep -q -- '--licenses' "$INSTALL_SH" \
  && ok "install.sh accepts SDK licenses (AGP self-serve downloads depend on it)" \
  || bad "install.sh never accepts SDK licenses — first Gradle build would fail"
grep -qE '^[[:space:]]*yes[[:space:]]*\|' "$INSTALL_SH" \
  && bad "license pipe uses \`yes |\` — SIGPIPE 141 under run.sh's pipefail makes every success a false WARN" \
  || ok "license pipe avoids \`yes |\` (no SIGPIPE false-WARN under pipefail)"
grep -q 'ANDROID_HOME=' "$INSTALL_SH" \
  && ok "install.sh writes ANDROID_HOME to /etc/environment" \
  || bad "install.sh never sets ANDROID_HOME"
grep -q 'chown -R "\$AGENT_USER"' "$INSTALL_SH" \
  && ok "SDK tree is chowned to the agent user (AGP writes into the SDK root)" \
  || bad "SDK tree stays root-owned — AGP build-time downloads would fail"
grep -qiE '"emulator"|system-images' "$INSTALL_SH" \
  && bad "install.sh installs emulator/AVD packages — out of the component's contract" \
  || ok "no emulator/AVD packages (headless contract)"

# 6. profiles.json: the swe-android preset = full-stack set + android-sdk, listed in order[].
jq -e . "$PROFILES_JSON" >/dev/null 2>&1 \
  && ok "profiles.json is valid JSON" || bad "profiles.json is not valid JSON"
jq -e '.order | index("swe-android")' "$PROFILES_JSON" >/dev/null 2>&1 \
  && ok "order[] lists swe-android" || bad "order[] does not list swe-android"
jq -e '.profiles[] | select(.slug=="swe-android") | .components | index("android-sdk")' "$PROFILES_JSON" >/dev/null 2>&1 \
  && ok "swe-android preset includes android-sdk" || bad "swe-android preset missing android-sdk"
full="$(jq -c '.profiles[] | select(.slug=="swe-full-stack") | .components' "$PROFILES_JSON")"
droid="$(jq -c '.profiles[] | select(.slug=="swe-android") | .components' "$PROFILES_JSON")"
[ "$droid" = "$(printf '%s' "$full" | jq -c '. + ["android-sdk", "android-emulator"]')" ] \
  && ok "swe-android = swe-full-stack components + android-sdk + android-emulator (exact superset)" \
  || bad "swe-android preset drifted from full-stack + android-sdk + android-emulator: $droid"

echo
if [ "$fail" = 0 ]; then echo "TEST PASSED"; else echo "TEST FAILED"; exit 1; fi
