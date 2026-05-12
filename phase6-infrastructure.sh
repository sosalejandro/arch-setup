#!/usr/bin/env bash
# Phase 6: infrastructure & cloud tooling.
# IaC (OpenTofu, Terraform), cloud CLIs (aws, az, gh), Kubernetes (kubectl/helm/k9s),
# Docker engine (NOT Docker Desktop — native containerd-backed), SOPS, age.
#
# Run as your normal user, over SSH. Idempotent.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "IaC: OpenTofu (preferred — MPL) + Terraform (BSL, included for compatibility)"
# OpenTofu is the community fork after Hashicorp moved Terraform to BSL.
# Most newer Terraform configs work in either; OpenTofu is the better default.
sudo pacman -S --needed --noconfirm opentofu terraform

# ---------------------------------------------------------------------------
log "Cloud CLIs: AWS v2, Azure, GitHub"
sudo pacman -S --needed --noconfirm aws-cli-v2 azure-cli github-cli

# ---------------------------------------------------------------------------
log "Kubernetes: kubectl, helm, k9s, kustomize"
sudo pacman -S --needed --noconfirm kubectl helm k9s kustomize

# ---------------------------------------------------------------------------
log "Docker engine (native — no Docker Desktop VM overhead)"
sudo pacman -S --needed --noconfirm docker docker-compose docker-buildx

# Enable docker daemon and add your user to the docker group (so you can run
# 'docker' without sudo). Group change requires a re-login.
sudo systemctl enable --now docker
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
  warn "Added $USER to the 'docker' group. Log out & back in (or 'newgrp docker') for it to take effect."
fi

# ---------------------------------------------------------------------------
log "Secrets: SOPS + age (file encryption with age-based key derivation)"
sudo pacman -S --needed --noconfirm sops age

# ---------------------------------------------------------------------------
log "Phase 6 complete."

cat <<EOF

Installed:
  - OpenTofu  : $(tofu version 2>/dev/null | head -1 || echo "(open new shell)")
  - Terraform : $(terraform version 2>/dev/null | head -1 || echo "(open new shell)")
  - aws       : $(aws --version 2>/dev/null)
  - az        : $(az version 2>/dev/null | head -3 || echo "(open new shell)")
  - gh        : $(gh --version 2>/dev/null | head -1)
  - kubectl   : $(kubectl version --client 2>/dev/null | head -1)
  - helm      : $(helm version --short 2>/dev/null)
  - k9s       : $(k9s version 2>/dev/null | head -1)
  - docker    : $(docker --version 2>/dev/null)
  - sops      : $(sops --version 2>/dev/null | head -1)
  - age       : $(age --version 2>/dev/null)

Auth / next steps:
  gh auth login                    # Github
  aws configure                    # AWS
  az login --use-device-code       # Azure (device-code flow works headless)
  age-keygen -o ~/.config/sops/age/keys.txt  # generate an age key for sops

Docker:
  Re-login (or 'newgrp docker'), then 'docker run hello-world' to verify.

EOF
