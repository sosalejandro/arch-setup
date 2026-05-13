#!/usr/bin/env bash
# Create + manage a fully-hardened ephemeral browsing VM (Lubuntu Live ISO).
#
# Strong OS isolation from the host:
#   - No persistent disk (runs entirely in RAM; shutdown = state wiped)
#   - No clipboard sharing between host and VM
#   - No shared filesystem / virtiofs / 9p mounts
#   - No USB passthrough
#   - UFW rule blocks VM from reaching host services (only DNS/DHCP allowed)
#
# Requires phase8-vms.sh to have been run first (KVM/QEMU/libvirt installed).
# Re-runnable: skips steps already completed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurable
# ---------------------------------------------------------------------------
VM_NAME="browse-eph"
RAM_MB=4096
VCPUS=2

# Lubuntu Live ISO — adjust release if newer LTS available
ISO_URL="https://cdimage.ubuntu.com/lubuntu/releases/24.04.3/release/lubuntu-24.04.3-desktop-amd64.iso"
ISO_DIR="$HOME/VMs/iso"
ISO_PATH="$ISO_DIR/lubuntu-live.iso"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Don't run as root — libvirt runs VMs under your user via group membership."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh >/dev/null      || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install >/dev/null || fail "virt-install not found. Install with: sudo pacman -S virt-install"
command -v curl >/dev/null       || fail "curl not found. Install with: sudo pacman -S curl"

# Group membership check
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Logout and back in after phase 8, then re-run."
fi

# Ensure libvirtd is up
if ! systemctl is-active --quiet libvirtd.socket && ! systemctl is-active --quiet libvirtd; then
  log "Starting libvirtd"
  sudo systemctl start libvirtd.socket
fi

# Ensure default network is up (it should be from phase 8)
if ! sudo virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
  log "Starting default libvirt network"
  sudo virsh net-start default 2>/dev/null || true
  sudo virsh net-autostart default 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
log "Downloading Lubuntu Live ISO if missing"
mkdir -p "$ISO_DIR"
if [[ ! -f "$ISO_PATH" ]]; then
  log "Fetching from $ISO_URL"
  curl -fL --progress-bar -o "$ISO_PATH.tmp" "$ISO_URL"
  mv "$ISO_PATH.tmp" "$ISO_PATH"
else
  log "ISO already present at $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Hardening on the host side: isolate the VM's NAT network from host services.
# The VM gets NAT'd internet via virbr0, but cannot reach services bound to
# the host. Only DNS (UDP 53) and DHCP (UDP 67) are allowed for VM operation.
# ---------------------------------------------------------------------------
log "Adding UFW rules to isolate VM network (virbr0) from host"
if systemctl is-active --quiet ufw; then
  if ! sudo ufw status verbose | grep -q "Anywhere on virbr0.*DENY"; then
    sudo ufw allow in on virbr0 to any proto udp port 53 comment 'VM DNS to host'  >/dev/null
    sudo ufw allow in on virbr0 to any proto udp port 67 comment 'VM DHCP to host' >/dev/null
    sudo ufw deny  in on virbr0 to any                  comment 'VM cannot reach host services' >/dev/null
    sudo ufw reload >/dev/null
    log "UFW: VM→host blocked except DNS/DHCP"
  else
    log "UFW rule already present, skipping"
  fi
else
  warn "ufw not active — VM network is NOT firewalled from host. Consider enabling ufw."
fi

# ---------------------------------------------------------------------------
# Create the VM if not already defined.
# Strategy: use virt-install to create + immediately shut it down,
# then patch the XML to remove the spicevmc channel (which is the clipboard
# sharing path), then redefine.
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
    --osinfo ubuntu24.04 \
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

  # Strip the spicevmc clipboard channel from the XML before defining
  log "Hardening XML: removing clipboard/copy-paste channel"
  python3 - <<EOF
import sys, re
p = '/tmp/${VM_NAME}.xml'
with open(p) as f: x = f.read()
# Remove <channel type='spicevmc'>...</channel> blocks
x = re.sub(r"<channel type='spicevmc'>.*?</channel>", '', x, flags=re.DOTALL)
# Remove <redirdev> entries (USB redirection)
x = re.sub(r"<redirdev[^/]*/>", '', x)
x = re.sub(r"<redirdev[^>]*>.*?</redirdev>", '', x, flags=re.DOTALL)
with open(p, 'w') as f: f.write(x)
EOF

  log "Defining hardened domain"
  sudo virsh define /tmp/${VM_NAME}.xml >/dev/null
  rm /tmp/${VM_NAME}.xml
fi

# ---------------------------------------------------------------------------
log "Done."

cat <<EOF

VM ready. Manage with:

  Start:        virsh -c qemu:///system start $VM_NAME
  View window:  virt-viewer -c qemu:///system $VM_NAME
  Shutdown:     virsh -c qemu:///system shutdown $VM_NAME
  Force off:    virsh -c qemu:///system destroy $VM_NAME
  Delete VM:    virsh -c qemu:///system undefine $VM_NAME

Or open virt-manager (RDP into the G7 first) for the GUI.

State on shutdown:
  - No persistent disk → all browser history, cookies, downloads vanish
  - RAM is wiped → no in-memory leakage to next session
  - Bookmarks / settings do NOT persist (this is by design — it's ephemeral)

Resource cost per session:
  - 4 GB RAM while running
  - ~3 GB on host disk for the ISO (permanent)
  - 0 GB additional per session

If you ever want to update the ISO:
  rm $ISO_PATH
  ./vm-ephemeral-browser.sh

EOF
