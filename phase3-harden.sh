#!/usr/bin/env bash
# Phase 3: hardening — optional
# Disables SSH password auth (key-only) and enables a simple ufw firewall.
# DO NOT RUN until SSH key auth from Windows is confirmed working,
# otherwise you will lock yourself out.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
# Sanity check: is there at least one authorized key on file? If not, refuse.
# ---------------------------------------------------------------------------
if [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
  fail "$HOME/.ssh/authorized_keys is missing or empty. Set up SSH key auth FIRST, otherwise this script will lock you out."
fi

warn "About to disable SSH password authentication."
warn "Confirm that you can SSH in from your Windows main laptop WITHOUT typing a password."
read -rp "Continue? (yes/NO) " ans
[[ "${ans,,}" == "yes" ]] || { log "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
log "Hardening sshd (PasswordAuthentication no, PermitRootLogin no)"
sudo cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
sudo sed -i \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
  /etc/ssh/sshd_config

# Make sure pubkey auth is still allowed (default is yes; this is defensive)
if ! grep -Eq '^[[:space:]]*PubkeyAuthentication[[:space:]]+yes' /etc/ssh/sshd_config; then
  echo 'PubkeyAuthentication yes' | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

sudo sshd -t || fail "sshd_config syntax check failed. Backup is at /etc/ssh/sshd_config.bak.*"
sudo systemctl restart sshd

# ---------------------------------------------------------------------------
# Disable firewalld if active. firewalld and ufw both install nftables rules
# into the same kernel hooks; running both produces silent failures where ufw
# rules appear correct (`ufw status`) but firewalld's chains actually filter
# packets first. EndeavourOS ships firewalld disabled by default but it can
# get enabled via Welcome app or manual configuration.
if systemctl is-active --quiet firewalld 2>/dev/null; then
  warn "firewalld is active — disabling it (cannot coexist with ufw)"
  sudo systemctl disable --now firewalld
fi

# ---------------------------------------------------------------------------
log "Installing and configuring ufw (allow ssh, rdp, mdns)"
sudo pacman -S --needed --noconfirm ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 3389/tcp comment 'xrdp'
sudo ufw allow 5353/udp comment 'mdns (avahi)'

# If Tailscale was set up before phase3, trust the mesh interface.
# (If phase4 runs later, it will add this rule itself — also handled there.)
if ip link show tailscale0 >/dev/null 2>&1; then
  log "Tailscale interface detected — allowing all incoming on tailscale0"
  sudo ufw allow in on tailscale0
fi

sudo ufw --force enable
sudo systemctl enable --now ufw

# ---------------------------------------------------------------------------
log "Phase 3 complete."

cat <<EOF

State now:
  - SSH: key-only, no passwords, no root login
  - Firewall: deny incoming except ssh / rdp / mdns
  - All other ports closed to the outside world

If you ever lose your SSH key and cannot get in:
  - Boot the EnOS USB live, unlock LUKS, mount the root, and re-enable
    PasswordAuthentication in /etc/ssh/sshd_config.
  - Or attach a keyboard + monitor to the laptop and edit it locally.

EOF
