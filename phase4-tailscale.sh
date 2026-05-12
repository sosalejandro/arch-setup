#!/usr/bin/env bash
# Phase 4: Tailscale mesh networking
# Installs Tailscale, enables MagicDNS-friendly hostname, opens ufw for tailscale0.
# Run on the G7. Re-runnable: if Tailscale is already up, it just refreshes ufw rules.
#
# Optional arg: a short hostname for this machine (e.g. ./phase4-tailscale.sh g7)
# When provided, sets both the system hostname AND the Tailscale hostname so
# MagicDNS resolves the short name from anywhere on the tailnet.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

NEW_HOSTNAME="${1:-}"

# ---------------------------------------------------------------------------
# Optional: rename hostname (must be a valid DNS label — lowercase, digits, hyphen).
if [[ -n "$NEW_HOSTNAME" ]]; then
  if [[ ! "$NEW_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    fail "Hostname '$NEW_HOSTNAME' is not a valid DNS label. Use lowercase letters, digits, and hyphens only (no leading/trailing hyphens, max 63 chars)."
  fi
  log "Renaming system hostname to '$NEW_HOSTNAME'"
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
fi

# ---------------------------------------------------------------------------
log "Installing Tailscale from official Arch extra repo"
sudo pacman -S --needed --noconfirm tailscale

# ---------------------------------------------------------------------------
log "Enabling tailscaled service"
sudo systemctl enable --now tailscaled

# ---------------------------------------------------------------------------
# Bring up Tailscale only if not already up (so this script is re-runnable).
# --ssh enables Tailscale SSH (optional alternative auth path — does not
# replace existing OpenSSH; both work side-by-side).
# ---------------------------------------------------------------------------
if sudo tailscale status >/dev/null 2>&1 && sudo tailscale status --json 2>/dev/null | grep -q '"BackendState": "Running"'; then
  log "Tailscale already up. Refreshing settings only."
  sudo tailscale set --ssh
  if [[ -n "$NEW_HOSTNAME" ]]; then
    log "Updating Tailscale hostname to '$NEW_HOSTNAME'"
    sudo tailscale set --hostname "$NEW_HOSTNAME"
  fi
else
  log "Bringing up Tailscale. You'll get an auth URL — open it on any browser, sign in, authorize this device."
  echo
  read -rp "Press Enter to continue..." _
  if [[ -n "$NEW_HOSTNAME" ]]; then
    sudo tailscale up --ssh --hostname "$NEW_HOSTNAME"
  else
    sudo tailscale up --ssh
  fi
fi

# ---------------------------------------------------------------------------
log "Opening ufw for the tailscale0 interface (trust mesh traffic)"
if systemctl is-active --quiet ufw 2>/dev/null; then
  # Allow all inbound on tailscale0 — the mesh is already authenticated + encrypted.
  if ! sudo ufw status verbose | grep -q "tailscale0"; then
    sudo ufw allow in on tailscale0
    sudo ufw reload
  else
    log "ufw already has a tailscale0 rule, skipping"
  fi
else
  warn "ufw is not active. Skipping firewall rule. If you run phase3-harden.sh later, re-run this script after to add the tailscale0 rule."
fi

# ---------------------------------------------------------------------------
log "Phase 4 complete."

TS_IPV4="$(sudo tailscale ip -4 2>/dev/null || echo 'unknown')"
TS_HOST="$(hostname)"

cat <<EOF

Tailscale state:
  IPv4 on tailnet:  ${TS_IPV4}
  Short hostname:   ${TS_HOST}

If MagicDNS is enabled in your tailnet (admin → DNS → MagicDNS), you can now reach this box
from any Tailscale-connected device by name:

  ssh ${USER}@${TS_HOST}

…from anywhere in the world. No port forwarding, no dynamic DNS.

On your Windows main laptop:
  1. Install Tailscale: https://tailscale.com/download/windows
  2. Sign in with the same account
  3. Verify in admin console: https://login.tailscale.com/admin/machines

Then on Windows you can update %USERPROFILE%\\.ssh\\config to use the Tailscale hostname:

  Host g7
      HostName ${TS_HOST}
      User ${USER}

EOF
