#!/usr/bin/env bash
# Create + manage an ephemeral Kali Linux VM using Kali's pre-built QEMU image.
#
# Why not the live ISO: as of 2026, Kali no longer offers a direct download for
# the live amd64 ISO (torrents only). They do still ship a pre-built qemu image
# (.7z, ~4 GB) as direct download. We treat it as a read-only "golden" disk and
# use libvirt's transient-disk feature: each VM start gets an automatic
# discard-on-shutdown overlay, so changes never persist across sessions.
#
# Same hardening defaults as vm-ephemeral-browser.sh:
#   - No clipboard sharing
#   - No USB passthrough
#   - No shared filesystem
#
# Network: NOT host-isolated by default (pentesting often needs network access).
# Set ISOLATE_FROM_HOST=1 to apply the host-isolation firewall rules.
#
# Requires phase8-vms.sh first.

set -euo pipefail

# ---------------------------------------------------------------------------
VM_NAME="kali-eph"
RAM_MB=6144
VCPUS=4

# Update KALI_VERSION when a newer release is in https://cdimage.kali.org/current/
KALI_VERSION="2026.1"
ARCHIVE_URL="https://cdimage.kali.org/current/kali-linux-${KALI_VERSION}-qemu-amd64.7z"
ARCHIVE_PATH="$HOME/VMs/iso/kali-qemu-${KALI_VERSION}.7z"
GOLDEN_DIR="$HOME/VMs/disks"
GOLDEN_PATH="$GOLDEN_DIR/kali-golden.qcow2"

ISOLATE_FROM_HOST="${ISOLATE_FROM_HOST:-0}"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Don't run as root."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh        >/dev/null || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install >/dev/null || fail "virt-install not found."
command -v curl         >/dev/null || fail "curl not found."
command -v 7z           >/dev/null || {
  log "Installing p7zip (needed to extract Kali's archive)"
  sudo pacman -S --needed --noconfirm p7zip
}

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Logout and back in after phase 8, then re-run."
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$GOLDEN_DIR"

# ---------------------------------------------------------------------------
log "Downloading Kali pre-built QEMU archive if missing"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  log "Fetching from $ARCHIVE_URL (~4 GB)"
  curl -fL --progress-bar -o "$ARCHIVE_PATH.tmp" "$ARCHIVE_URL"
  mv "$ARCHIVE_PATH.tmp" "$ARCHIVE_PATH"
else
  log "Archive already present at $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | cut -f1))"
fi

# ---------------------------------------------------------------------------
log "Extracting Kali QEMU image (golden disk)"
if [[ ! -f "$GOLDEN_PATH" ]]; then
  # IMPORTANT: extract on a disk-backed filesystem, not /tmp (which is tmpfs
  # on Arch and would consume RAM). 10-15 GB during extraction.
  TMP_EXTRACT="$GOLDEN_DIR/.extract-tmp"
  rm -rf "$TMP_EXTRACT"
  mkdir -p "$TMP_EXTRACT"

  log "Extracting archive to $TMP_EXTRACT (disk-backed, ~10-15 GB during extraction)"
  7z x -o"$TMP_EXTRACT" "$ARCHIVE_PATH" >/dev/null

  EXTRACTED_QCOW=$(find "$TMP_EXTRACT" -maxdepth 3 -name '*.qcow2' -type f | head -1)
  if [[ -z "$EXTRACTED_QCOW" ]]; then
    rm -rf "$TMP_EXTRACT"
    fail "No .qcow2 found in extracted archive. Inspect $ARCHIVE_PATH manually."
  fi

  log "Moving golden disk to $GOLDEN_PATH"
  mv "$EXTRACTED_QCOW" "$GOLDEN_PATH"
  rm -rf "$TMP_EXTRACT"

  log "Marking golden disk read-only (required for transient overlay)"
  chmod 444 "$GOLDEN_PATH"
else
  log "Golden disk already present at $GOLDEN_PATH ($(du -h "$GOLDEN_PATH" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Optional: apply host-isolation firewall rules
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
# Define the VM with a transient disk so changes auto-discard on shutdown.
# transient=on tells libvirt to create a private overlay on start and delete
# it on stop, leaving the golden disk untouched.
# ---------------------------------------------------------------------------
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping creation. To recreate: virsh undefine --nvram $VM_NAME"
else
  log "Defining VM '$VM_NAME' (RAM=${RAM_MB} MB, vCPU=${VCPUS}, transient disk)"
  sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --import \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --osinfo debian13 \
    --boot uefi,menu=on \
    --disk path="$GOLDEN_PATH",format=qcow2,bus=virtio,readonly=on,transient=on \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --video qxl \
    --sound none \
    --controller type=usb,model=none \
    --rng /dev/urandom \
    --noautoconsole \
    --print-xml=1 > /tmp/${VM_NAME}.xml

  log "Hardening XML: removing clipboard channel + USB redirection"
  python3 - <<EOF
import re
p = '/tmp/${VM_NAME}.xml'
with open(p) as f: x = f.read()
m = re.search(r'<domain\b.*?</domain>', x, flags=re.DOTALL)
if m: x = m.group(0)
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

Kali ephemeral VM ready.

How ephemeral works here:
  - The golden disk ($GOLDEN_PATH) is read-only.
  - Each 'virsh start' creates a private overlay; all changes (browser history,
    installed packages, files) go to the overlay.
  - 'virsh shutdown' destroys the overlay → next start = pristine Kali again.
  - This is a libvirt 'transient' disk; no manual cleanup needed.

Manage:
  Start:        virsh -c qemu:///system start $VM_NAME
  View:         virt-viewer -c qemu:///system $VM_NAME
  Shutdown:     virsh -c qemu:///system shutdown $VM_NAME
  Force off:    virsh -c qemu:///system destroy $VM_NAME

Default credentials: kali / kali (change on first boot if you reuse the VM).

Host isolation: $([ "$ISOLATE_FROM_HOST" = "1" ] && echo "ENABLED" || echo "DISABLED (re-run with ISOLATE_FROM_HOST=1 to enable)")

Exporting findings before shutdown:
  scp findings.txt user@elsewhere:dest/
  # or 'tailscale send' / SMB / whatever you have set up

To free disk space, you can delete the original .7z archive — the golden disk
stays where it is and the archive is no longer needed:
  rm $ARCHIVE_PATH

EOF
