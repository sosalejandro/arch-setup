#!/usr/bin/env bash
# Create a stateful Windows 11 work VM.
#
# TWO modes, auto-detected based on what file you have at ~/VMs/iso/ :
#
#   Mode A (PREFERRED) — Microsoft's free Windows 11 Dev VM
#     Pre-installed Win11 + VS Code + WSL + Visual Studio Community + dev tools.
#     90-day trial, legal, no install required — VM boots straight to desktop.
#     Workflow: snapshot it at "first boot" and revert when trial expires.
#     Download (~20 GB) the *Hyper-V* version of the Dev VM from:
#       https://aka.ms/windev
#     Inside the .zip you'll find a .VHDX file. Extract to:
#       ~/VMs/iso/WinDev.vhdx
#     Run this script — it converts VHDX → qcow2 and defines the VM.
#
#   Mode B — fresh install from Windows 11 ISO
#     For full control or if you have a retail license. The script does the
#     definitions; you do the click-through install in virt-viewer.
#     Place the ISO at: ~/VMs/iso/win11.iso
#
# License options (VMs cannot inherit OEM keys):
#   - Dev VM: free 90-day trial, revert snapshot to reset
#   - Manual install + skip product key: works forever with a small watermark
#   - Retail Win11 key: $30-$140, legally activates VM
#
# Sized for a lightweight .NET + VS Code workload.

set -euo pipefail

# ---------------------------------------------------------------------------
VM_NAME="win-work"
RAM_MB=8192
VCPUS=4
DISK_SIZE_GB=60   # qcow2 max — only consumed as used

# Source files in user home (you download these manually).
VHDX_PATH="$HOME/VMs/iso/WinDev.vhdx"
WIN_ISO_PATH="$HOME/VMs/iso/win11.iso"
# libvirt-managed VM media must live where qemu can read it
# (qemu drops privileges and cannot traverse mode-750 home dirs).
LIBVIRT_DIR="/var/lib/libvirt/images"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
VIRTIO_ISO_PATH="$LIBVIRT_DIR/virtio-win.iso"
WIN_ISO_DEST="$LIBVIRT_DIR/win11.iso"
DISK_PATH="$LIBVIRT_DIR/${VM_NAME}.qcow2"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Don't run as root."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh         >/dev/null || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install  >/dev/null || fail "virt-install not found."
command -v qemu-img      >/dev/null || fail "qemu-img not found."
command -v curl          >/dev/null || fail "curl not found."
command -v swtpm         >/dev/null || fail "swtpm not found. Run ./phase8-vms.sh first."

[[ -d /usr/share/edk2 ]] || [[ -d /usr/share/OVMF ]] || \
  fail "edk2-ovmf not found. Run ./phase8-vms.sh first."

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Logout and back in after phase 8, then re-run."
fi

mkdir -p "$(dirname "$WIN_ISO_PATH")"
sudo mkdir -p "$LIBVIRT_DIR"

# ---------------------------------------------------------------------------
# Decide which mode to run in
# ---------------------------------------------------------------------------
MODE=""
if [[ -f "$VHDX_PATH" ]]; then
  MODE="devvm"
  log "Detected Microsoft Dev VM VHDX at $VHDX_PATH"
elif [[ -f "$WIN_ISO_PATH" ]]; then
  MODE="iso"
  log "Detected Windows ISO at $WIN_ISO_PATH (install mode)"
else
  cat <<EOF

ERROR: No Windows source found. Provide one of:

  A. Microsoft Dev VM VHDX (RECOMMENDED — pre-installed dev tools, 90-day trial)
       Download:  https://aka.ms/windev
       Pick:      "Windows 11 Hyper-V" (downloads a .zip ~20 GB)
       Extract:   the .vhdx file inside to: $VHDX_PATH

  B. Windows 11 install ISO
       Download:  https://www.microsoft.com/software-download/windows11
       Save as:   $WIN_ISO_PATH

  After placing either file, re-run this script.

EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Mode A — Dev VM: convert VHDX to qcow2, no install
# ---------------------------------------------------------------------------
if [[ "$MODE" == "devvm" ]]; then
  if [[ ! -f "$DISK_PATH" ]]; then
    log "Converting VHDX → qcow2 (~5-10 min for a 20 GB image)"
    sudo qemu-img convert -f vhdx -O qcow2 -p "$VHDX_PATH" "$DISK_PATH"
    sudo chown root:libvirt "$DISK_PATH"
    sudo chmod 660 "$DISK_PATH"
    log "Conversion done. qcow2 size: $(sudo du -h "$DISK_PATH" | cut -f1)"
  else
    log "qcow2 disk already exists at $DISK_PATH (skipping conversion)"
  fi
fi

# ---------------------------------------------------------------------------
# Mode B — ISO install: create blank qcow2 + download VirtIO drivers
# ---------------------------------------------------------------------------
if [[ "$MODE" == "iso" ]]; then
  if [[ ! -f "$DISK_PATH" ]]; then
    log "Creating blank ${DISK_SIZE_GB} GB qcow2 disk"
    sudo qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE_GB}G"
    sudo chown root:libvirt "$DISK_PATH"
    sudo chmod 660 "$DISK_PATH"
  fi

  # Copy Windows ISO into libvirt-accessible path
  if [[ ! -f "$WIN_ISO_DEST" ]]; then
    log "Copying Windows ISO to libvirt-accessible path"
    sudo cp "$WIN_ISO_PATH" "$WIN_ISO_DEST"
    sudo chmod 644 "$WIN_ISO_DEST"
  fi

  if [[ ! -f "$VIRTIO_ISO_PATH" ]]; then
    log "Downloading VirtIO drivers ISO (~500 MB)"
    sudo curl -fL --progress-bar -o "$VIRTIO_ISO_PATH.tmp" "$VIRTIO_ISO_URL"
    sudo mv "$VIRTIO_ISO_PATH.tmp" "$VIRTIO_ISO_PATH"
    sudo chmod 644 "$VIRTIO_ISO_PATH"
  fi
fi

# ---------------------------------------------------------------------------
# Define the VM
# ---------------------------------------------------------------------------
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping creation. To recreate: virsh undefine --nvram $VM_NAME"
else
  log "Defining VM '$VM_NAME' (RAM=${RAM_MB} MB, vCPU=${VCPUS})"

  if [[ "$MODE" == "devvm" ]]; then
    # The Dev VM VHDX was prepared for Hyper-V; it doesn't have VirtIO drivers
    # pre-installed. Use SATA for disk (compatible without extra drivers) and
    # let the user upgrade to VirtIO later if they want better performance.
    sudo virt-install \
      --connect qemu:///system \
      --name "$VM_NAME" \
      --import \
      --memory "$RAM_MB" \
      --vcpus "$VCPUS" \
      --cpu host-passthrough \
      --osinfo win11 \
      --boot uefi,menu=on \
      --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
      --disk path="$DISK_PATH",format=qcow2,bus=sata \
      --network network=default,model=e1000e \
      --graphics spice,listen=127.0.0.1 \
      --video qxl \
      --sound default \
      --rng /dev/urandom \
      --features smm.state=on \
      --noautoconsole
  else
    # Fresh install: use VirtIO disk + network (drivers loaded from ISO during install)
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
      --disk path="$WIN_ISO_DEST",device=cdrom,bus=sata,target.dev=sda \
      --disk path="$VIRTIO_ISO_PATH",device=cdrom,bus=sata,target.dev=sdb \
      --network network=default,model=virtio \
      --graphics spice,listen=127.0.0.1 \
      --video qxl \
      --sound default \
      --rng /dev/urandom \
      --features smm.state=on \
      --noautoconsole
  fi
fi

# ---------------------------------------------------------------------------
log "VM defined."

if [[ "$MODE" == "devvm" ]]; then
cat <<EOF

Dev VM mode — VM boots straight into Windows 11. No install needed.

Start + view:
  virsh -c qemu:///system start $VM_NAME
  virt-viewer -c qemu:///system $VM_NAME

On first boot:
  - Initial Windows OOBE (set up local user, accept settings) — ~5 min
  - You'll be on the desktop with VS Code, .NET, WSL pre-installed
  - 90-day trial activation. Watermark says "Windows License is expired" near day 80.

CRITICAL — immediately take a snapshot of the clean state:
  virsh -c qemu:///system snapshot-create-as $VM_NAME pristine "Clean Dev VM, day 0"
  # Or via virt-manager: Snapshots → + → name 'pristine'

When the trial nags or you want to start fresh, revert:
  virsh -c qemu:///system shutdown $VM_NAME
  virsh -c qemu:///system snapshot-revert $VM_NAME pristine
  virsh -c qemu:///system start $VM_NAME
  # → Back to day 0, 90 fresh days

Optional after first boot — install spice-guest-tools for clipboard sync + auto-resize:
  https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe

If you later want VirtIO performance (faster disk/network), install virtio-win-guest-tools
inside the VM, then shut down and edit the XML to switch bus=sata → bus=virtio.

EOF
else
cat <<EOF

ISO install mode — interactive Windows installation.

Start + view:
  virsh -c qemu:///system start $VM_NAME
  virt-viewer -c qemu:///system $VM_NAME

In the installer:
  1. Language → Next → Install now
  2. "I don't have a product key" if installing unactivated
  3. "Custom: Install Windows only"
  4. Empty disk list → Load driver → CD Drive (virtio-win) → amd64 → w11
     → select viostor → Next. Then load NetKVM/amd64/w11 too.
  5. Now the VirtIO disk appears. Select, install (~10 min, reboots once).
  6. After Windows boots, install .NET SDK + VS Code:
       https://dotnet.microsoft.com/download
       https://code.visualstudio.com/download
  7. Install spice-guest-tools for clipboard + resize:
       https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe

Take a snapshot once you have a working baseline:
  virsh -c qemu:///system snapshot-create-as $VM_NAME baseline "Win11 + .NET + VS Code"

EOF
fi
