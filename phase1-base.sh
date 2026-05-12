#!/usr/bin/env bash
# Phase 1: base remote-access stack
# Run ON THE G7, while you still have keyboard + monitor attached.
# After this completes successfully, test SSH + RDP from Windows, then close the lid.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root. Run as your normal user; the script will sudo as needed."

# ---------------------------------------------------------------------------
log "Updating system"
sudo pacman -Syu --noconfirm

# ---------------------------------------------------------------------------
log "Installing official-repo packages (openssh, avahi, nss-mdns)"
sudo pacman -S --needed --noconfirm openssh avahi nss-mdns

# ---------------------------------------------------------------------------
log "Installing xrdp + xorgxrdp from AUR"
if ! command -v yay >/dev/null 2>&1; then
  fail "yay not found. EndeavourOS ships with yay; install it manually before re-running."
fi
yay -S --needed --noconfirm xrdp xorgxrdp

# ---------------------------------------------------------------------------
log "Enabling services: sshd, xrdp, avahi-daemon"
sudo systemctl enable --now sshd
sudo systemctl enable --now xrdp
sudo systemctl enable --now avahi-daemon

# ---------------------------------------------------------------------------
log "Configuring xrdp -> Xfce session (defensive: three layers)"

# Layer 1: ~/.xsession — many xrdp builds source this
cat > "$HOME/.xsession" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x "$HOME/.xsession"

# Layer 2: ~/.xinitrc — fallback for Arch/xinit-style launches
cat > "$HOME/.xinitrc" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x "$HOME/.xinitrc"

# Layer 3: /etc/xrdp/startwm.sh — system-level override that guarantees Xfce launches
# Back up the original first, then replace with a minimal Xfce launcher.
if [[ -f /etc/xrdp/startwm.sh ]] && ! grep -q '# managed-by: g7-setup' /etc/xrdp/startwm.sh; then
  sudo cp /etc/xrdp/startwm.sh "/etc/xrdp/startwm.sh.bak.$(date +%s)"
  sudo tee /etc/xrdp/startwm.sh >/dev/null <<'EOF'
#!/bin/sh
# managed-by: g7-setup
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec /usr/bin/startxfce4
EOF
  sudo chmod +x /etc/xrdp/startwm.sh
fi

# ---------------------------------------------------------------------------
log "Enabling mDNS so <hostname>.local resolves on the LAN"
# nss-mdns documentation recommends inserting 'mdns_minimal [NOTFOUND=return]'
# right after 'mymachines' on the hosts: line.
NSS=/etc/nsswitch.conf
if ! grep -Eq '^hosts:.*mdns_minimal' "$NSS"; then
  sudo cp "$NSS" "${NSS}.bak.$(date +%s)"
  sudo python3 -c "
import re, sys
p = '$NSS'
with open(p) as f: s = f.read()
def fix(m):
    line = m.group(0)
    if 'mdns_minimal' in line: return line
    return re.sub(r'\\bmymachines\\b', 'mymachines mdns_minimal [NOTFOUND=return]', line)
s2 = re.sub(r'^hosts:.*$', fix, s, flags=re.M)
open(p,'w').write(s2)
" 2>/dev/null || {
    # Python fallback failed (Python missing?); use sed instead
    sudo sed -i -E 's/(^hosts:.*\bmymachines\b)( |\t)+/\1 mdns_minimal [NOTFOUND=return] /' "$NSS"
  }
fi

# ---------------------------------------------------------------------------
log "Ignoring lid-close events (no suspend when laptop is closed)"
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/lid.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
sudo systemctl restart systemd-logind

# ---------------------------------------------------------------------------
log "Phase 1 complete."

cat <<EOF

From your Windows main laptop, test:
  ping g7.local
  ssh ${USER}@g7.local
  mstsc /v:g7.local

If RDP shows a blank screen or xterm instead of Xfce, the system-level
/etc/xrdp/startwm.sh patch is the authoritative fix and is already applied.
If problems persist, run:
  sudo journalctl -u xrdp -n 100
  sudo journalctl -u xrdp-sesman -n 100

Once SSH + RDP both work, close the lid and reconnect over SSH from Windows.
Then run:
  ./phase2-dev.sh

EOF
