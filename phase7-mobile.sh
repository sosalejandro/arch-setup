#!/usr/bin/env bash
# Phase 7: mobile development.
# JDK, Gradle, ADB/fastboot, Android command-line SDK tools, watchman for RN.
# React Native runs on the Node stack from phase 2.
#
# Note: Android SDK installation is done as the user (not root) because
# everything lives under ~/Android/Sdk and licence acceptance is per-user.
#
# Run as your normal user, over SSH. Idempotent.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "Java (OpenJDK 21 LTS) and Gradle"
# Android Gradle Plugin (AGP) officially supports JDK 17 and JDK 21 only.
# JDK 26 (current non-LTS) is too new for the Android toolchain — builds may
# warn or fail. We install jdk21-openjdk specifically for Android work;
# any newer JDK you have (e.g. jdk-openjdk, Coursier's bundled JDK) keeps
# working for Scala / general JVM dev. Multiple JDKs coexist under /usr/lib/jvm.
sudo pacman -S --needed --noconfirm jdk21-openjdk gradle

# Only set JDK 21 as the SYSTEM default if there isn't already a default.
# This preserves whatever you picked previously (e.g. JDK 26 for Scala).
if ! archlinux-java status 2>/dev/null | grep -q '^\s*[[:alnum:]-]\+ \(default\)'; then
  sudo archlinux-java set java-21-openjdk
  warn "No default JDK was set — set jdk21 as system default."
else
  log "Keeping existing system-default JDK: $(archlinux-java get)"
fi

# Capture JDK 21 path for Android-specific use (so Gradle on Android can
# point JAVA_HOME at it explicitly without flipping the system default).
JDK21_HOME=/usr/lib/jvm/java-21-openjdk
if ! grep -q 'ANDROID_JAVA_HOME' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<EOF

# Use this for Android Gradle builds when your default JDK is newer than 21:
#   JAVA_HOME="\$ANDROID_JAVA_HOME" ./gradlew assembleDebug
export ANDROID_JAVA_HOME=$JDK21_HOME
EOF
fi

# ---------------------------------------------------------------------------
log "Android platform tools (adb, fastboot)"
sudo pacman -S --needed --noconfirm android-tools

# ---------------------------------------------------------------------------
log "Android SDK command-line tools (AUR)"
# 'android-sdk-cmdline-tools-latest' provides sdkmanager + avdmanager.
# We avoid the full 'android-studio' since this box is headless and the IDE
# is overkill — code-server / VS Code Remote / your Windows IDE handles the GUI side.
yay -S --needed --noconfirm android-sdk-cmdline-tools-latest

# Standard ANDROID_HOME location — matches what Android Studio uses.
export ANDROID_HOME="$HOME/Android/Sdk"
mkdir -p "$ANDROID_HOME"

# Wire ANDROID_HOME + tool paths into .bashrc once
if ! grep -q 'ANDROID_HOME' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# Android SDK
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
EOF
fi

# Install commonly-needed SDK components. Accept all licences (-y not supported;
# yes-piping is the canonical pattern).
SDKMANAGER=/opt/android-sdk/cmdline-tools/latest/bin/sdkmanager
if [[ ! -x "$SDKMANAGER" ]]; then
  warn "sdkmanager not found at $SDKMANAGER — install path may have changed. Skipping SDK component install."
else
  log "Accepting Android SDK licences (one-time)"
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true

  log "Installing core SDK components: platform-tools, latest platform, build-tools, emulator, system image"
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0" \
    "emulator" \
    "system-images;android-34;google_apis;x86_64" || warn "Some SDK components failed to install — retry manually if needed."
fi

# ---------------------------------------------------------------------------
# Watchman: skipped on purpose.
# The AUR 'watchman' package depends on a flock of Facebook libraries
# (folly, fizz, fbthrift, fb303, mvfst) pinned to exact versions that
# routinely fall out of sync with the AUR. Result: pacman/yay can't resolve.
#
# React Native's Metro bundler falls back to Linux inotify without watchman.
# The 'EMFILE / too many open files' errors people blame on missing watchman
# are actually the kernel's default inotify watch limit (~65k) being too low
# for the file count in node_modules + project sources. Raising that limit
# makes RN run cleanly on Linux without watchman.
log "Raising fs.inotify.max_user_watches for React Native (Meta's recommendation: 524288)"
INOTIFY_CONF=/etc/sysctl.d/99-inotify.conf
if [[ ! -f "$INOTIFY_CONF" ]] || ! grep -q max_user_watches "$INOTIFY_CONF"; then
  echo "fs.inotify.max_user_watches=524288" | sudo tee "$INOTIFY_CONF" >/dev/null
  echo "fs.inotify.max_queued_events=32768" | sudo tee -a "$INOTIFY_CONF" >/dev/null
  echo "fs.inotify.max_user_instances=512" | sudo tee -a "$INOTIFY_CONF" >/dev/null
  sudo sysctl --system >/dev/null
fi

# If you specifically need watchman (some monorepos / fbjs tooling),
# Meta ships prebuilt linux-x64 binaries on GitHub:
#   https://github.com/facebook/watchman/releases
# Download, extract, and put 'watchman' on your PATH. The build-from-source
# AUR route is not worth the breakage.

# ---------------------------------------------------------------------------
# Allow the user to access USB-connected Android devices without root.
# The android-tools package ships udev rules; ensure your user is in the 'adbusers' group.
if getent group adbusers >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx adbusers; then
    sudo usermod -aG adbusers "$USER"
    warn "Added $USER to 'adbusers' group. Log out & back in (or 'newgrp adbusers') so it applies."
  fi
fi

# ---------------------------------------------------------------------------
log "Phase 7 complete."

cat <<EOF

Installed:
  - Java (default) : $(java -version 2>&1 | head -1)
  - JDK 21 path    : $JDK21_HOME (use via \$ANDROID_JAVA_HOME for Android)
  - Gradle         : $(gradle --version 2>/dev/null | grep '^Gradle' || echo "(open new shell)")
  - adb            : $(adb --version 2>/dev/null | head -1)
  - sdkmanager     : $SDKMANAGER
  - ANDROID_HOME   = $ANDROID_HOME

JDK selection for Android Gradle builds:
  AGP officially supports JDK 17 / 21. If your default is JDK 26 (e.g. from Scala/
  Coursier), pass JDK 21 to gradle explicitly:
    JAVA_HOME=\$ANDROID_JAVA_HOME ./gradlew assembleDebug
  Or change the system default once with:
    sudo archlinux-java set java-21-openjdk
  Show installed JDKs:
    archlinux-java status

React Native:
  After re-opening your shell:
    npx @react-native-community/cli init MyApp
  Watchman is NOT installed (AUR dependency rot). Metro uses inotify instead;
  the watch limits are pre-tuned to 524288 in /etc/sysctl.d/99-inotify.conf.
  If you ever do need watchman, grab the prebuilt binary from:
    https://github.com/facebook/watchman/releases

USB device debugging:
  Plug device → 'adb devices'. If "no permissions", re-login (group change pending).
  Wireless ADB: 'adb tcpip 5555' then 'adb connect <phone-ip>:5555' (do this on
  the trusted Tailscale interface only — never on public LAN/WAN).

Emulator on the G7:
  KVM acceleration is available (you have an Intel CPU with VT-x).
  Make sure /dev/kvm is accessible: 'ls -l /dev/kvm' — should be group 'kvm'.
  If yourself isn't in 'kvm' group: 'sudo usermod -aG kvm \$USER'.

EOF
