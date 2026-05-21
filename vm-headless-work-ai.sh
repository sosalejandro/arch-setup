#!/usr/bin/env bash
# Create a stateful, headless Ubuntu 24.04 LTS work VM for AI / Python / Node dev.
#
# Optimized for low overhead: server cloud image (no desktop), provisioned
# via cloud-init, joins Tailscale automatically on first boot.
# Intended access pattern: Cursor Remote-SSH from your Windows laptop —
# the VM is the runtime, the IDE renders on the client.
#
# Prerequisites on the G7 host:
#   - phase8-vms.sh has been run (KVM/QEMU/libvirt + virt-install)
#   - An ISO builder is installed (any of genisoimage / mkisofs / xorriso)
#       sudo pacman -S cdrtools           # provides mkisofs
#       sudo pacman -S libisoburn         # provides xorriso (alternative)
#   - You have an SSH public key (default: ~/.ssh/id_ed25519.pub)
#   - You have a Tailscale pre-auth key stored at:
#       ~/.config/arch-setup/tailscale-authkey-headless-work-ai
#     Generate it at https://login.tailscale.com/admin/settings/keys
#       Reusable=off, Ephemeral=off, Pre-approved=on
#       Tag: tag:work-ai  (define the tag in your ACL policy first)
#
# After this script finishes, cloud-init runs inside the VM (~2-4 min).
# Then SSH in via Tailscale MagicDNS and run phase9-headless-work-ai.sh
# to install the Python/Node/Docker/Claude dev stack.
#
# Re-runnable: skips steps already completed.
# Use --recreate to destroy + reprovision.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurable defaults (overridable via env vars or flags)
# ---------------------------------------------------------------------------
VM_NAME="${VM_NAME:-headless-work-ai}"
RAM_MB="${VM_RAM_MB:-8192}"
VCPUS="${VM_CPUS:-4}"
DISK_GB="${VM_DISK_GB:-60}"
USERNAME="${VM_USERNAME:-$USER}"

# Ubuntu 24.04 LTS server cloud image (rolling pointer to latest point release).
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
SHA256SUMS_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"

# libvirt's qemu drops privileges and cannot traverse mode-750 home dirs.
# Store VM media in libvirt's standard system path.
LIBVIRT_DIR="/var/lib/libvirt/images"
CACHE_DIR="$HOME/.cache/arch-setup/cloud-images"
BASE_IMG_PATH="$CACHE_DIR/noble-server-cloudimg-amd64.img"
DISK_PATH="$LIBVIRT_DIR/${VM_NAME}.qcow2"
SEED_PATH="$LIBVIRT_DIR/${VM_NAME}-seed.iso"

SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
TS_AUTHKEY_PATH="${TS_AUTHKEY_PATH:-$HOME/.config/arch-setup/tailscale-authkey-${VM_NAME}}"

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--recreate] [--cpus=N] [--ram-mb=N] [--disk-gb=N] [--name=NAME]

Provisions a headless Ubuntu 24.04 work VM via libvirt + cloud-init,
joined to your Tailscale tailnet on first boot.

Flags:
  --recreate          Destroy + reprovision an existing VM of this name
  --cpus=N            vCPU count        (default: $VCPUS)
  --ram-mb=N          Memory in MB      (default: $RAM_MB)
  --disk-gb=N         Disk size in GB   (default: $DISK_GB)
  --name=NAME         VM name           (default: $VM_NAME)
  -h, --help          Show this help

Env vars (lower precedence than flags):
  VM_NAME, VM_CPUS, VM_RAM_MB, VM_DISK_GB, VM_USERNAME,
  SSH_PUBKEY_PATH, TS_AUTHKEY_PATH

See the script header comment for setup requirements.
EOF
}

RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --recreate)     RECREATE=1 ;;
    --cpus=*)       VCPUS="${arg#*=}" ;;
    --ram-mb=*)     RAM_MB="${arg#*=}" ;;
    --disk-gb=*)    DISK_GB="${arg#*=}" ;;
    --name=*)       VM_NAME="${arg#*=}"
                    DISK_PATH="$LIBVIRT_DIR/${VM_NAME}.qcow2"
                    SEED_PATH="$LIBVIRT_DIR/${VM_NAME}-seed.iso"
                    TS_AUTHKEY_PATH="$HOME/.config/arch-setup/tailscale-authkey-${VM_NAME}" ;;
    -h|--help)      usage; exit 0 ;;
    *)              warn "Unknown argument: $arg" ;;
  esac
done

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v virsh        >/dev/null || fail "virsh not found. Run ./phase8-vms.sh first."
command -v virt-install >/dev/null || fail "virt-install not found. Run ./phase8-vms.sh first."
command -v qemu-img     >/dev/null || fail "qemu-img not found."
command -v curl         >/dev/null || fail "curl not found."

# ISO builder for the cloud-init seed disk
SEED_TOOL=""
if   command -v genisoimage >/dev/null; then SEED_TOOL="genisoimage"
elif command -v mkisofs     >/dev/null; then SEED_TOOL="mkisofs"
elif command -v xorriso     >/dev/null; then SEED_TOOL="xorriso"
else
  fail "No ISO builder found. Install one:  sudo pacman -S cdrtools  (or libisoburn for xorriso)"
fi

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
  fail "$USER not in 'libvirt' group. Log out and back in after phase 8, then re-run."
fi

[[ -f "$SSH_PUBKEY_PATH" ]] || \
  fail "SSH public key not found at $SSH_PUBKEY_PATH. Generate one: ssh-keygen -t ed25519"

if [[ ! -f "$TS_AUTHKEY_PATH" ]]; then
  cat <<EOF

ERROR: Tailscale pre-auth key not found at:
  $TS_AUTHKEY_PATH

How to create one:
  1. Open: https://login.tailscale.com/admin/settings/keys
  2. Click 'Generate auth key'
  3. Settings: Reusable=off, Ephemeral=off, Pre-approved=on
     Tags:    tag:work-ai  (define this tag in your ACL policy first)
  4. Copy the key (starts with 'tskey-auth-...') into the file above:
       mkdir -p "$(dirname "$TS_AUTHKEY_PATH")"
       umask 077
       printf '%s\n' 'tskey-auth-xxxxxxxxxxxxxxxx' > "$TS_AUTHKEY_PATH"

Then re-run this script.

EOF
  exit 1
fi

# Credential hygiene
KEY_PERMS="$(stat -c '%a' "$TS_AUTHKEY_PATH" 2>/dev/null || echo '???')"
if [[ "$KEY_PERMS" != "600" && "$KEY_PERMS" != "400" ]]; then
  warn "Tailscale auth key has permissive permissions ($KEY_PERMS). Fixing to 600."
  chmod 600 "$TS_AUTHKEY_PATH"
fi

# ---------------------------------------------------------------------------
# Optional: destroy + undefine existing VM
# ---------------------------------------------------------------------------
if [[ "$RECREATE" -eq 1 ]] && sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "Destroying + undefining existing VM '$VM_NAME' (--recreate)"
  sudo virsh destroy "$VM_NAME" 2>/dev/null || true
  if ! sudo virsh undefine --nvram --remove-all-storage "$VM_NAME" 2>/dev/null; then
    sudo virsh undefine "$VM_NAME" 2>/dev/null || true
  fi
  sudo rm -f "$DISK_PATH" "$SEED_PATH"
fi

# ---------------------------------------------------------------------------
# Download Ubuntu cloud image (cached) and verify checksum
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"
sudo mkdir -p "$LIBVIRT_DIR"

if [[ ! -f "$BASE_IMG_PATH" ]]; then
  log "Downloading Ubuntu 24.04 cloud image (~700 MB qcow2)"
  curl -fL --progress-bar -o "$BASE_IMG_PATH.tmp" "$CLOUD_IMG_URL"

  log "Verifying SHA256 against published SHA256SUMS"
  EXPECTED="$(curl -fsSL "$SHA256SUMS_URL" | awk '/noble-server-cloudimg-amd64\.img$/ {print $1; exit}')"
  ACTUAL="$(sha256sum "$BASE_IMG_PATH.tmp" | awk '{print $1}')"
  if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    rm -f "$BASE_IMG_PATH.tmp"
    fail "Checksum mismatch. Expected: ${EXPECTED:-<not found>}  Got: $ACTUAL"
  fi
  mv "$BASE_IMG_PATH.tmp" "$BASE_IMG_PATH"
  log "Checksum OK"
else
  log "Cloud image already cached at $BASE_IMG_PATH"
fi

# ---------------------------------------------------------------------------
# Per-VM disk (copy from base image, resize)
# ---------------------------------------------------------------------------
if [[ ! -f "$DISK_PATH" ]]; then
  log "Copying base image to per-VM disk"
  sudo cp "$BASE_IMG_PATH" "$DISK_PATH"
  sudo chown root:libvirt "$DISK_PATH"
  sudo chmod 660 "$DISK_PATH"

  log "Resizing disk to ${DISK_GB} GB (cloud-init growpart will expand FS on first boot)"
  sudo qemu-img resize "$DISK_PATH" "${DISK_GB}G"
else
  log "VM disk already exists at $DISK_PATH (skipping copy)"
fi

# ---------------------------------------------------------------------------
# Build the cloud-init seed ISO (NoCloud datasource)
# ---------------------------------------------------------------------------
TMPDIR_CI="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CI"' EXIT

SSH_KEY_CONTENT="$(cat "$SSH_PUBKEY_PATH")"
TS_AUTHKEY="$(tr -d '\n' < "$TS_AUTHKEY_PATH")"

cat > "$TMPDIR_CI/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%Y%m%d%H%M%S)
local-hostname: $VM_NAME
EOF

# Heredoc is unquoted: $USERNAME, $VM_NAME, $SSH_KEY_CONTENT, $TS_AUTHKEY expand.
# Cloud-init template vars like $UPTIME are escaped as \$UPTIME.
cat > "$TMPDIR_CI/user-data" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
preserve_hostname: false

users:
  - name: $USERNAME
    gecos: $USERNAME
    groups: [sudo]
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $SSH_KEY_CONTENT

ssh_pwauth: false
disable_root: true

package_update: true
package_upgrade: false

packages:
  - curl
  - ca-certificates
  - gnupg
  - lsb-release
  - apt-transport-https
  - git
  - build-essential
  - unzip
  - jq
  - htop
  - tmux
  - ripgrep
  - fd-find
  - direnv
  - python3-pip

write_files:
  - path: /etc/ssh/sshd_config.d/99-headless-work-ai.conf
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      KbdInteractiveAuthentication no
    owner: root:root
    permissions: '0644'

  - path: /etc/sysctl.d/99-vm-tweaks.conf
    content: |
      vm.swappiness = 10
      fs.inotify.max_user_watches = 524288
      fs.inotify.max_user_instances = 512
    owner: root:root
    permissions: '0644'

runcmd:
  - [ systemctl, restart, ssh ]
  - [ sysctl, --system ]
  - 'curl -fsSL https://tailscale.com/install.sh | sh'
  - 'tailscale up --authkey=$TS_AUTHKEY --hostname=$VM_NAME --ssh --accept-routes'
  - 'mkdir -p /var/lib/cloud/instance/markers'
  - 'date -u +%FT%TZ > /var/lib/cloud/instance/markers/bootstrap-complete'

final_message: "Cloud-init done after \$UPTIME seconds. SSH in via Tailscale and run phase9-headless-work-ai.sh"
EOF

log "Building cloud-init seed ISO with $SEED_TOOL"
case "$SEED_TOOL" in
  genisoimage)
    genisoimage -quiet -output "$TMPDIR_CI/seed.iso" -volid cidata -joliet -rock \
      "$TMPDIR_CI/user-data" "$TMPDIR_CI/meta-data"
    ;;
  mkisofs)
    mkisofs -quiet -output "$TMPDIR_CI/seed.iso" -volid cidata -joliet -rock \
      "$TMPDIR_CI/user-data" "$TMPDIR_CI/meta-data"
    ;;
  xorriso)
    xorriso -as mkisofs -quiet -output "$TMPDIR_CI/seed.iso" -volid cidata -joliet -rock \
      "$TMPDIR_CI/user-data" "$TMPDIR_CI/meta-data"
    ;;
esac

sudo install -o root -g libvirt -m 0640 "$TMPDIR_CI/seed.iso" "$SEED_PATH"

# ---------------------------------------------------------------------------
# Define the VM (idempotent)
# ---------------------------------------------------------------------------
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping creation. To recreate: $0 --recreate"
else
  log "Defining VM '$VM_NAME' (RAM=${RAM_MB} MB, vCPU=${VCPUS}, disk=${DISK_GB} GB)"
  sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --import \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --osinfo ubuntu24.04 \
    --disk "path=$DISK_PATH,format=qcow2,bus=virtio" \
    --disk "path=$SEED_PATH,device=cdrom,bus=sata" \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --serial pty \
    --rng /dev/urandom \
    --noautoconsole
fi

# Make sure it's running
if ! sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
  log "Starting VM"
  sudo virsh -c qemu:///system start "$VM_NAME"
fi

# ---------------------------------------------------------------------------
log "VM started. Cloud-init runs on first boot (~2-4 min)."

cat <<EOF

Next steps:

  1. Wait ~3 min for cloud-init (Tailscale join, base packages).
     Watch live:
       sudo virsh -c qemu:///system console $VM_NAME
       (Ctrl+] to detach without stopping the VM.)

     Verify when complete:
       ls -l /var/lib/cloud/instance/markers/bootstrap-complete  # inside the VM

  2. From any Tailscale-connected device, SSH in via MagicDNS:
       ssh $USERNAME@$VM_NAME

  3. Inside the VM, clone arch-setup and run Phase 9 (dev stack):
       git clone https://github.com/sosalejandro/arch-setup.git
       cd arch-setup && ./phase9-headless-work-ai.sh

  4. From Cursor on Windows:
       Install Cursor + the Remote-SSH extension.
       Add SSH host: $VM_NAME
       Connect — Cursor auto-deploys its server inside the VM.

VM management:
  Start:      virsh -c qemu:///system start $VM_NAME
  Shutdown:   virsh -c qemu:///system shutdown $VM_NAME
  Force off:  virsh -c qemu:///system destroy $VM_NAME
  Console:    virsh -c qemu:///system console $VM_NAME
  Recreate:   $0 --recreate

EOF
