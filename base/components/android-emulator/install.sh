# components/android-emulator/install.sh — Android Emulator + headless AVD (on-device runs).
#
# Sourced by base/run.sh when `android-emulator` is in AGENT_COMPONENTS. Runs as
# root at provision time, AFTER android-sdk in the toolchain loop (it needs the
# sdkmanager + pre-accepted licenses that component provides). Installs the
# emulator package + one x86_64 system image, creates the shared headless AVD
# `sb-default` as the agent user, and ships the on-demand sb-avd-start /
# sb-avd-stop helpers — deliberately NO boot service, so the ~2-3 GB the emulator
# wants stays free until an SD/QA run actually boots it. The emulator is usable
# ONLY with KVM: install still completes without /dev/kvm (image + AVD land so a
# later resize/migration can enable them), but sb-avd-start hard-refuses, so a
# discovery run degrades to the source-scaffold path with a clear reason instead
# of a silent 10-minute software-rendered crawl. Nested-virt reality (verified
# 2026-07-21): NO Hetzner Cloud type exposes it (CX cpuinfo + a dedicated CCX23
# boot probe both showed vmx/svm=0); AWS 8th-gen Intel (m8i/c8i) declares
# nested-virtualization in DescribeInstanceTypes; GCP N-series needs a
# create-time flag. Always verify /dev/kvm on the box. Idempotent.

step "Component: Android Emulator"

ANDROID_SDK_DIR=/opt/android-sdk
SDKMANAGER="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/avdmanager"
# One image, pinned to the android-sdk component's warm platform (36): x86_64 +
# Google APIs — the smallest image that runs real app flows under uiautomator.
ANDROID_EMULATOR_IMAGE="system-images;android-36;google_apis;x86_64"
SB_AVD_NAME=sb-default

if [ ! -x "$SDKMANAGER" ]; then
  log "WARN: android-sdk cmdline-tools missing — android-emulator requires the android-sdk component; skipping"
else
  "$SDKMANAGER" --sdk_root="$ANDROID_SDK_DIR" "emulator" "$ANDROID_EMULATOR_IMAGE" >>"$LOG_FILE" 2>&1 \
    || log "WARN: emulator/system-image install failed"

  # /dev/kvm access for the agent user. The kvm group ships with Ubuntu's udev
  # defaults; created defensively for minimal images. Runs invoke sb-avd-start in
  # fresh sessions, so provision-time membership is picked up there.
  getent group kvm >/dev/null 2>&1 || groupadd --system kvm
  usermod -aG kvm "$AGENT_USER" || log "WARN: usermod -aG kvm ${AGENT_USER} failed"
  if [ -e /dev/kvm ]; then
    log "android-emulator: /dev/kvm present — hardware acceleration available"
  else
    log "WARN: /dev/kvm ABSENT — emulator installed but unusable here (sb-avd-start will refuse; AWS virtual instances have no nested virt)"
  fi

  # The emulator binary lives under <sdk>/emulator (not platform-tools).
  ln -sf "$ANDROID_SDK_DIR/emulator/emulator" /usr/local/bin/emulator
  ln -sf "$AVDMANAGER" /usr/local/bin/avdmanager

  # Shared AVD, created as the agent user (the emulator writes locks + snapshots
  # into ~/.android/avd). No --force: recreating would cold-boot a warmed AVD.
  # NOT `yes |` (SIGPIPE 141 under pipefail — see android-sdk); avdmanager asks
  # one bounded "custom hardware profile?" question, so a single `no` suffices.
  if [ -d "$AGENT_HOME/.android/avd/${SB_AVD_NAME}.avd" ]; then
    log "android-emulator: AVD ${SB_AVD_NAME} already exists"
  else
    printf 'no\n' | runuser -u "$AGENT_USER" -- env ANDROID_HOME="$ANDROID_SDK_DIR" ANDROID_SDK_ROOT="$ANDROID_SDK_DIR" \
      "$AVDMANAGER" create avd -n "$SB_AVD_NAME" -k "$ANDROID_EMULATOR_IMAGE" --device pixel_7 >>"$LOG_FILE" 2>&1 \
      || log "WARN: AVD ${SB_AVD_NAME} creation failed"
  fi

  # New SDK dirs (emulator/, system-images/) follow the android-sdk ownership rule
  # (AGP/sdkmanager self-serve writes into the SDK root at build time).
  chown -R "$AGENT_USER":"$AGENT_USER" "$ANDROID_SDK_DIR" \
    || log "WARN: chown ${AGENT_USER} ${ANDROID_SDK_DIR} failed"

  install -m 0755 "$BASE_DIR/components/android-emulator/sb-avd-start" /usr/local/bin/sb-avd-start \
    || log "WARN: sb-avd-start install failed"
  install -m 0755 "$BASE_DIR/components/android-emulator/sb-avd-stop" /usr/local/bin/sb-avd-stop \
    || log "WARN: sb-avd-stop install failed"

  # Emulator-driver MCP: lets Claude Code drive the AVD (accessibility-tree
  # taps/reads over adb) with no per-session npx fetch. base/15-claude-mcp.sh
  # registers it as an MCP server for android-emulator agents; the package
  # exposes the `mcp-server-mobile` bin. Pinned — its tools take an explicit
  # `device` argument, a contract that can shift between versions.
  npm i -g @mobilenext/mobile-mcp@0.0.62 >>"$LOG_FILE" 2>&1 \
    || log "WARN: mobile-mcp global install failed — Claude Code emulator control unavailable"

  log "android-emulator: image [${ANDROID_EMULATOR_IMAGE}] avd [${SB_AVD_NAME}] kvm [$([ -e /dev/kvm ] && echo yes || echo no)]"
fi
