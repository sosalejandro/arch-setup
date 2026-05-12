#!/usr/bin/env bash
# Sanity check the setup. Reports the state of every component;
# does not change anything.

set -uo pipefail

green() { printf "\033[1;32m%s\033[0m" "$*"; }
red()   { printf "\033[1;31m%s\033[0m" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m" "$*"; }

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    printf "  %s %s\n" "$(green "[ok]")" "$svc is active"
  else
    printf "  %s %s\n" "$(red "[!!]")" "$svc is NOT active"
  fi
}

check_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    local v
    v="$("$cmd" --version 2>&1 | head -1 || true)"
    printf "  %s %-12s %s\n" "$(green "[ok]")" "$cmd" "${v:-installed}"
  else
    printf "  %s %s not installed\n" "$(red "[!!]")" "$cmd"
  fi
}

echo
echo "=== services ==="
for s in sshd xrdp avahi-daemon systemd-logind ufw; do check_service "$s"; done

# Conflict check: ufw and firewalld must not both be active. If they are,
# firewalld silently filters packets even though `ufw status` looks correct.
if systemctl is-active --quiet ufw && systemctl is-active --quiet firewalld; then
  printf "  %s firewalld is ALSO active — disables ufw rules silently. Run: sudo systemctl disable --now firewalld\n" "$(red "[!!]")"
fi

echo
echo "=== commands ==="
for c in git node npm claude fnm yay nvim rg fd htop; do check_command "$c"; done

echo
echo "=== lid behavior ==="
# Query the running logind daemon directly via DBus (authoritative —
# `systemctl show systemd-logind` doesn't expose daemon config as unit properties).
LID_VAL="$(busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | awk -F'"' '{print $2}')"
if [[ "$LID_VAL" == "ignore" ]]; then
  printf "  %s lid-close is ignored (will not suspend)\n" "$(green "[ok]")"
else
  printf "  %s lid-close = '%s' — drop in /etc/systemd/logind.conf.d/lid.conf and restart systemd-logind\n" \
    "$(red "[!!]")" "${LID_VAL:-unknown}"
fi

echo
echo "=== mDNS ==="
if grep -E '^hosts:.*mdns4_minimal' /etc/nsswitch.conf >/dev/null; then
  printf "  %s nsswitch.conf has mdns4_minimal\n" "$(green "[ok]")"
else
  printf "  %s nsswitch.conf missing mdns4_minimal\n" "$(red "[!!]")"
fi

echo
echo "=== SSH config ==="
if sudo grep -Eq '^PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config 2>/dev/null; then
  printf "  %s SSH password auth is disabled (key-only)\n" "$(green "[ok]")"
else
  printf "  %s SSH password auth is enabled — run phase3-harden.sh once key auth works\n" "$(yellow "[..]")"
fi

echo
echo "=== xrdp session ==="
if [[ -f "$HOME/.xsession" ]] && grep -q startxfce4 "$HOME/.xsession"; then
  printf "  %s ~/.xsession launches Xfce\n" "$(green "[ok]")"
else
  printf "  %s ~/.xsession is missing or does not launch Xfce\n" "$(red "[!!]")"
fi

echo
echo "=== network ==="
ip -4 addr show scope global | awk '/inet /{printf "  ip: %s (%s)\n", $2, $NF}' || true
echo "  hostname: $(hostname).local"

echo
