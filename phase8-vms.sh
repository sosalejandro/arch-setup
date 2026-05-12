#!/usr/bin/env bash
# Phase 8: virtualization stack — KVM/QEMU + libvirt + virt-manager.
# Enables running Linux / Windows / Kali guests on the G7.
#
# Note: the G7 has a single dGPU (RTX 2060/2070) which is being used by the host;
# GPU passthrough to a Windows guest would require a second GPU (or vGPU support
# which 20-series Nvidia consumer cards don't support officially). CPU-only VMs
# work fine with KVM acceleration (VT-x on your Intel 11th gen).
#
# Run as your normal user, over SSH. Idempotent.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "Sanity check: CPU virtualization support"
if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
  fail "CPU does not advertise VT-x/AMD-V. Enable virtualization in BIOS first."
fi
if [[ ! -e /dev/kvm ]]; then
  warn "/dev/kvm not present. The kvm_intel or kvm_amd module may not be loaded — proceeding, but check 'dmesg | grep -i kvm' after install."
fi

# ---------------------------------------------------------------------------
log "Installing KVM/QEMU + libvirt + virt-manager + UEFI/networking helpers"
sudo pacman -S --needed --noconfirm \
  qemu-full \
  libvirt \
  virt-manager \
  virt-viewer \
  dnsmasq \
  bridge-utils \
  edk2-ovmf \
  swtpm \
  iptables-nft

# qemu-full pulls all qemu-system-*, which is the right default for a workstation.
# edk2-ovmf provides UEFI firmware (required for modern Windows + macOS guests).
# swtpm gives software TPM 2.0 (required for Windows 11 guests).

# ---------------------------------------------------------------------------
log "Enabling libvirtd and related services"
sudo systemctl enable --now libvirtd.socket
sudo systemctl enable --now virtlogd.socket

# ---------------------------------------------------------------------------
log "Adding $USER to libvirt + kvm groups (run VMs without sudo)"
for grp in libvirt kvm; do
  if getent group "$grp" >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$grp"; then
    sudo usermod -aG "$grp" "$USER"
    warn "Added $USER to '$grp' group. Log out & back in (or 'newgrp $grp') so it takes effect."
  fi
done

# ---------------------------------------------------------------------------
log "Starting the default libvirt network (NAT-based, 192.168.122.0/24)"
sudo virsh net-autostart default 2>/dev/null || true
sudo virsh net-start default 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Phase 8 complete."

cat <<EOF

Installed:
  - qemu-system-x86_64 : $(qemu-system-x86_64 --version 2>/dev/null | head -1)
  - libvirtd           : $(systemctl is-active libvirtd.socket 2>/dev/null)
  - virt-manager       : $(virt-manager --version 2>/dev/null)

Verify KVM:
  ls -l /dev/kvm          # should show group 'kvm', readable
  lsmod | grep kvm        # kvm_intel should be loaded

Creating a VM:
  1. RDP into the G7 (mstsc /v:g7) — virt-manager needs an X session.
  2. Run 'virt-manager' from a terminal in Xfce.
  3. New VM → choose your ISO. virt-manager auto-detects most OSes.

ISOs you might want, ordered by storage location:
  ~/VMs/iso/kali-linux.iso        https://www.kali.org/get-kali/
  ~/VMs/iso/Win11.iso             https://www.microsoft.com/software-download/windows11
  ~/VMs/iso/ubuntu-server.iso     https://ubuntu.com/download/server

For Windows 11 guests:
  - Enable swtpm + UEFI in the VM hardware config (TPM 2.0 + Secure Boot required).
  - Use VirtIO drivers ISO from Fedora for storage/network performance:
    https://github.com/virtio-win/virtio-win-pkg-scripts

For headless VM management (no RDP):
  virsh list --all                    # list all VMs
  virsh start <name>                  # start a VM
  virsh shutdown <name>               # graceful shutdown
  virsh console <name>                # text console (for Linux guests with serial console)

EOF
