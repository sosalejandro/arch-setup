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
# Android Gradle Plugin 8.x supports JDK 17/21; 21 is current LTS as of late 2025.
sudo pacman -S --needed --noconfirm jdk21-openjdk gradle
# Set the default Java if multiple JDKs are installed
sudo archlinux-java set java-21-openjdk 2>/dev/null || true

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
log "Watchman (React Native file watching) — AUR"
yay -S --needed --noconfirm watchman

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
  - Java     : $(java -version 2>&1 | head -1)
  - Gradle   : $(gradle --version 2>/dev/null | grep '^Gradle' || echo "(open new shell)")
  - adb      : $(adb --version 2>/dev/null | head -1)
  - sdkman.  : $SDKMANAGER
  - ANDROID_HOME = $ANDROID_HOME

React Native:
  After re-opening your shell:
    npx react-native init MyApp
  Or with the new CLI:
    npx @react-native-community/cli init MyApp

USB device debugging:
  Plug device → 'adb devices'. If "no permissions", re-login (group change pending).
  Wireless ADB: 'adb tcpip 5555' then 'adb connect <phone-ip>:5555' (do this on
  the trusted Tailscale interface only — never on public LAN/WAN).

Emulator on the G7:
  KVM acceleration is available (you have an Intel CPU with VT-x).
  Make sure /dev/kvm is accessible: 'ls -l /dev/kvm' — should be group 'kvm'.
  If yourself isn't in 'kvm' group: 'sudo usermod -aG kvm \$USER'.

EOF
