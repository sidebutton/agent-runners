# components/android-sdk/install.sh — JDK 17 + Android SDK (headless build toolchain).
#
# Sourced by base/run.sh when `android-sdk` is in AGENT_COMPONENTS. Runs as root at
# provision time. Installs OpenJDK 17 (the floor for Gradle 9 / AGP 8+) from the
# Ubuntu archive, the Android cmdline-tools under /opt/android-sdk, accepts the SDK
# licenses, and warms the baseline packages (platform-tools, platform 36,
# build-tools) so an agent's first Gradle build doesn't cold-download them. The SDK
# tree is chowned to the agent user because AGP auto-downloads any further SDK
# packages INTO the SDK root during builds — license acceptance here is what makes
# that self-serve path work unattended. Deliberately NO emulator/AVD: cloud agents
# have no KVM guarantee and no BLE/NFC radios, so the component targets headless
# assemble/lint/unit-test parity with a repo's CI, not on-device runs. Idempotent.

step "Component: Android SDK"

ANDROID_SDK_DIR=/opt/android-sdk
# dl.google.com publishes cmdline-tools as versioned zips only — pin the build and
# bump deliberately (the tools self-update the rest of the SDK via sdkmanager).
ANDROID_CMDLINE_TOOLS_BUILD=13114709
# Baseline warm set — track the highest compileSdk the fleet's Android repos use.
# A build needing anything else self-serves via AGP (licenses are pre-accepted).
ANDROID_SDK_PACKAGES=("platform-tools" "platforms;android-36" "build-tools;36.0.0")

if command -v java >/dev/null 2>&1; then
  log "java already installed: $(java -version 2>&1 | head -1)"
else
  apt-get install "${APT_OPTS[@]}" openjdk-17-jdk-headless || log "WARN: openjdk-17 install failed"
  log "java: $(java -version 2>&1 | head -1 || echo not-installed)"
fi

SDKMANAGER="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
if [ -x "$SDKMANAGER" ]; then
  log "android cmdline-tools already installed: $("$SDKMANAGER" --version 2>/dev/null | head -1)"
else
  _zip=/tmp/android-cmdline-tools.zip
  if curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-connrefused \
       "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip" \
       -o "$_zip"; then
    rm -rf /tmp/android-cmdline-tools
    if unzip -q "$_zip" -d /tmp/android-cmdline-tools; then
      # The zip unpacks to cmdline-tools/ — sdkmanager requires the tools to live
      # at <sdk>/cmdline-tools/latest/ to resolve its own SDK root.
      mkdir -p "$ANDROID_SDK_DIR/cmdline-tools"
      rm -rf "$ANDROID_SDK_DIR/cmdline-tools/latest"
      mv /tmp/android-cmdline-tools/cmdline-tools "$ANDROID_SDK_DIR/cmdline-tools/latest" \
        || log "WARN: cmdline-tools move failed"
    else
      log "WARN: cmdline-tools unzip failed"
    fi
    rm -rf "$_zip" /tmp/android-cmdline-tools
  else
    log "WARN: could not download Android cmdline-tools — Android SDK not installed"
  fi
fi

if [ -x "$SDKMANAGER" ]; then
  # NOT `yes |`: under run.sh's pipefail, `yes` dies SIGPIPE (141) when sdkmanager
  # exits, turning every SUCCESSFUL license pass into a false WARN. A bounded
  # printf fits the pipe buffer and exits 0, so the guard reflects sdkmanager.
  printf 'y\n%.0s' {1..200} | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_DIR" --licenses >>"$LOG_FILE" 2>&1 \
    || log "WARN: SDK license acceptance failed"
  "$SDKMANAGER" --sdk_root="$ANDROID_SDK_DIR" "${ANDROID_SDK_PACKAGES[@]}" >>"$LOG_FILE" 2>&1 \
    || log "WARN: SDK package install failed"
  ln -sf "$ANDROID_SDK_DIR/platform-tools/adb" /usr/local/bin/adb
  ln -sf "$SDKMANAGER" /usr/local/bin/sdkmanager
  # AGP writes into the SDK root when it self-serves missing packages at build time.
  chown -R "$AGENT_USER":"$AGENT_USER" "$ANDROID_SDK_DIR" \
    || log "WARN: chown ${AGENT_USER} ${ANDROID_SDK_DIR} failed"
  # System-wide SDK location for login shells + Gradle (ANDROID_HOME is the
  # current name; ANDROID_SDK_ROOT kept for tools that still read the old one).
  grep -q '^ANDROID_HOME=' /etc/environment 2>/dev/null \
    || echo "ANDROID_HOME=${ANDROID_SDK_DIR}" >> /etc/environment
  grep -q '^ANDROID_SDK_ROOT=' /etc/environment 2>/dev/null \
    || echo "ANDROID_SDK_ROOT=${ANDROID_SDK_DIR}" >> /etc/environment
  log "android-sdk: platforms [$(ls "$ANDROID_SDK_DIR/platforms" 2>/dev/null | xargs)] — ANDROID_HOME=${ANDROID_SDK_DIR}"
fi
