#!/usr/bin/env bash
# Create a stateful Windows 11 work VM (UEFI, TPM 2.0, VirtIO).
#
# Sized for a lightweight .NET + VS Code workload:
#   - 40 GB qcow2 disk (thin-provisioned — actual usage ~30 GB after install)
#   - 8 GB RAM
#   - 4 vCPUs
#   - UEFI + Secure Boot via edk2-ovmf (required by Win11)
#   - swtpm TPM 2.0 (required by Win11)
#   - VirtIO disk + network for performance (drivers loaded during install)
#
# This script does NOT download Windows. You must obtain the ISO yourself:
#   https://www.microsoft.com/software-download/windows11
# Place it at: $HOME/VMs/iso/win11.iso
#
# Activation: VMs cannot inherit your laptop's OEM key. Options:
#   1. Install unactivated (skip the product key prompt during setup).
#      Watermark + locked personalization, but full functionality otherwise.
#   2. Use Microsoft's free Windows 11 Development VM (90-day trial):
#      https://aka.ms/windev — comes preinstalled with VS Code + dev tools.
#      Use that VHDX/VMDK directly instead of this script's qcow2 disk.
#   3. Buy a retail Win11 license (retail = VM-transferable).

set -euo pipefail

# ---------------------------------------------------------------------------
VM_NAME="win-work"
RAM_MB=8192
VCPUS=4
DISK_SIZE_GB=40

WIN_ISO_PATH="$HOME/VMs/iso/win11.iso"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
VIRTIO_ISO_PATH="$HOME/VMs/iso/virtio-win.iso"
DISK_DIR="$HOME/VMs/disks"
DISK_PATH="$DISK_DIR/${VM_NAME}.qcow2"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Don't run as root."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh >/dev/null      || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install >/dev/null || fail "virt-install not found."
command -v qemu-img >/dev/null   || fail "qemu-img not found."
command -v curl >/dev/null       || fail "curl not found."
command -v swtpm >/dev/null      || fail "swtpm not found. Run ./phase8-vms.sh first."

# Verify edk2-ovmf is installed (UEFI firmware for Windows 11)
[[ -d /usr/share/edk2 ]] || [[ -d /usr/share/OVMF ]] || \
  fail "edk2-ovmf not found. Run ./phase8-vms.sh first."

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Logout and back in after phase 8, then re-run."
fi

# ---------------------------------------------------------------------------
log "Checking for Windows 11 ISO at $WIN_ISO_PATH"
mkdir -p "$(dirname "$WIN_ISO_PATH")"
if [[ ! -f "$WIN_ISO_PATH" ]]; then
  cat <<EOF

ERROR: Windows ISO not found at:
  $WIN_ISO_PATH

Get the official ISO from Microsoft (free download):
  https://www.microsoft.com/software-download/windows11

Pick: "Download Windows 11 Disk Image (ISO) for x64 devices"

Then transfer to the G7. From your Windows main laptop:
  scp Win11.iso g7:$WIN_ISO_PATH

Re-run this script after the ISO is in place.

Alternative — Microsoft's free Win11 Dev VM (pre-installed VS Code):
  https://aka.ms/windev
  (Use that VHDX directly; you don't need this script for it.)

EOF
  exit 1
fi
log "Windows ISO present: $(du -h "$WIN_ISO_PATH" | cut -f1)"

# ---------------------------------------------------------------------------
log "Downloading VirtIO drivers ISO (needed by Windows installer to see VirtIO disk)"
if [[ ! -f "$VIRTIO_ISO_PATH" ]]; then
  curl -fL --progress-bar -o "$VIRTIO_ISO_PATH.tmp" "$VIRTIO_ISO_URL"
  mv "$VIRTIO_ISO_PATH.tmp" "$VIRTIO_ISO_PATH"
else
  log "VirtIO ISO already present"
fi

# ---------------------------------------------------------------------------
log "Creating ${DISK_SIZE_GB} GB qcow2 disk (thin-provisioned)"
mkdir -p "$DISK_DIR"
if [[ ! -f "$DISK_PATH" ]]; then
  qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE_GB}G"
else
  log "Disk already exists at $DISK_PATH"
fi

# ---------------------------------------------------------------------------
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping creation. To recreate: virsh undefine --nvram $VM_NAME"
else
  log "Defining VM '$VM_NAME' (RAM=${RAM_MB} MB, vCPU=${VCPUS}, disk=${DISK_SIZE_GB} GB)"
  sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --osinfo win11 \
    --boot uefi,menu=on \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk path="$DISK_PATH",format=qcow2,bus=virtio \
    --disk path="$WIN_ISO_PATH",device=cdrom,bus=sata,target.dev=sda \
    --disk path="$VIRTIO_ISO_PATH",device=cdrom,bus=sata,target.dev=sdb \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --video qxl \
    --sound default \
    --rng /dev/urandom \
    --features smm.state=on \
    --noautoconsole
fi

# ---------------------------------------------------------------------------
log "VM defined. Next: interactive Windows installation."

cat <<EOF

Start the install:
  virsh -c qemu:///system start $VM_NAME
  virt-viewer -c qemu:///system $VM_NAME

In the Windows installer:
  1. Select language, click Next, click "Install now".
  2. **Click "I don't have a product key"** if you want to install unactivated.
     (See activation notes at the top of this script for legal options.)
  3. Select "Windows 11 Pro" (or whichever edition you want).
  4. Accept license, choose "Custom: Install Windows only".
  5. **Disk selection** — initially empty. Click "Load driver":
     - Browse → CD Drive (E:) virtio-win → amd64 → w11
     - Select the viostor driver, click Next
     - Then "Load driver" again for the network: select "NetKVM/amd64/w11"
     - Now the VirtIO disk should appear — select it, click Next
  6. Windows installs (~10 min). It'll reboot — eject the install ISO when prompted.

After install:
  - Sign in with a local account if possible (skip Microsoft account if you don't want it).
  - Install .NET SDK: https://dotnet.microsoft.com/download
  - Install VS Code: https://code.visualstudio.com/download
  - Install spice-guest-tools for clipboard + dynamic resolution:
      https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe

Manage the VM:
  Start:    virsh -c qemu:///system start $VM_NAME
  View:     virt-viewer -c qemu:///system $VM_NAME
  Shutdown: virsh -c qemu:///system shutdown $VM_NAME
  Snapshot: virsh -c qemu:///system snapshot-create-as $VM_NAME clean-install "Clean Win11 + .NET + VS Code"
  Revert:   virsh -c qemu:///system snapshot-revert $VM_NAME clean-install

Recommended: take a snapshot named 'clean-install' immediately after .NET and VS Code
are installed, before you start work. Lets you roll back if anything breaks.

EOF
