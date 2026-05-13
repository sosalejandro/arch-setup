#!/usr/bin/env bash
# Create + manage an ephemeral Kali Linux VM (Live ISO, no persistence).
#
# Threat model: penetration-testing / CTF / forensics work where
# reproducibility matters and you want zero artifact on the host.
#
# Same hardening as vm-ephemeral-browser.sh:
#   - No persistent disk (live boot, RAM-only)
#   - No clipboard sharing
#   - No USB passthrough
#   - No shared filesystem
#
# Network: NOT isolated from the host (unlike browse-eph) because pentesting
# sometimes needs to reach the host or be reachable. If you want Kali fully
# isolated from your host, set ISOLATE_FROM_HOST=1 before running.
#
# Requires phase8-vms.sh first.

set -euo pipefail

# ---------------------------------------------------------------------------
VM_NAME="kali-eph"
RAM_MB=6144
VCPUS=4

# Kali Live ISO (Xfce flavour — lightest, default Kali experience)
# Update the URL if a newer release exists.
ISO_URL="https://cdimage.kali.org/kali-2026.1/kali-linux-2026.1-live-amd64.iso"
ISO_DIR="$HOME/VMs/iso"
ISO_PATH="$ISO_DIR/kali-live.iso"

# Optional: set to 1 to apply the same host-isolation firewall rules as browse-eph
ISOLATE_FROM_HOST="${ISOLATE_FROM_HOST:-0}"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Don't run as root."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh >/dev/null      || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install >/dev/null || fail "virt-install not found."
command -v curl >/dev/null       || fail "curl not found."

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Logout and back in after phase 8, then re-run."
fi

# ---------------------------------------------------------------------------
log "Downloading Kali Live ISO if missing"
mkdir -p "$ISO_DIR"
if [[ ! -f "$ISO_PATH" ]]; then
  log "Fetching from $ISO_URL (~4 GB)"
  curl -fL --progress-bar -o "$ISO_PATH.tmp" "$ISO_URL"
  mv "$ISO_PATH.tmp" "$ISO_PATH"
else
  log "ISO already present at $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Optional: apply host-isolation rules (off by default — pentesting sometimes
# needs to interact with the host).
# ---------------------------------------------------------------------------
if [[ "$ISOLATE_FROM_HOST" == "1" ]]; then
  if systemctl is-active --quiet ufw; then
    if ! sudo ufw status verbose | grep -q "Anywhere on virbr0.*DENY"; then
      log "Applying host-isolation UFW rules (ISOLATE_FROM_HOST=1)"
      sudo ufw allow in on virbr0 to any proto udp port 53 >/dev/null
      sudo ufw allow in on virbr0 to any proto udp port 67 >/dev/null
      sudo ufw deny  in on virbr0 to any                  >/dev/null
      sudo ufw reload >/dev/null
    fi
  else
    warn "ufw not active — cannot apply isolation rules."
  fi
fi

# ---------------------------------------------------------------------------
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping creation"
else
  log "Defining VM '$VM_NAME' (RAM=${RAM_MB} MB, vCPU=${VCPUS}, no persistent disk)"
  sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --osinfo debian13 \
    --cdrom "$ISO_PATH" \
    --boot uefi,menu=on \
    --disk none \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --video qxl \
    --sound none \
    --controller type=usb,model=none \
    --rng /dev/urandom \
    --noautoconsole \
    --print-xml > /tmp/${VM_NAME}.xml

  log "Hardening XML: removing clipboard channel + USB redirection"
  python3 - <<EOF
import re
p = '/tmp/${VM_NAME}.xml'
with open(p) as f: x = f.read()
x = re.sub(r"<channel type='spicevmc'>.*?</channel>", '', x, flags=re.DOTALL)
x = re.sub(r"<redirdev[^/]*/>", '', x)
x = re.sub(r"<redirdev[^>]*>.*?</redirdev>", '', x, flags=re.DOTALL)
with open(p, 'w') as f: f.write(x)
EOF

  sudo virsh define /tmp/${VM_NAME}.xml >/dev/null
  rm /tmp/${VM_NAME}.xml
fi

# ---------------------------------------------------------------------------
log "Done."

cat <<EOF

Kali ephemeral VM ready. Manage with:

  Start:        virsh -c qemu:///system start $VM_NAME
  View window:  virt-viewer -c qemu:///system $VM_NAME
  Shutdown:     virsh -c qemu:///system shutdown $VM_NAME
  Force off:    virsh -c qemu:///system destroy $VM_NAME

Kali Live default login: kali / kali

Host isolation: $([ "$ISOLATE_FROM_HOST" = "1" ] && echo "ENABLED (re-runnable without env var)" || echo "DISABLED (re-run with ISOLATE_FROM_HOST=1 to enable)")

State on shutdown:
  - All Kali tooling resets to default
  - No findings persist (export findings before shutdown!)
  - Use 'scp file user@host:dir' to copy out findings before stopping the VM

EOF
