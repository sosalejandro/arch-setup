#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1091
# SC2016: ensure_path() deliberately stores LITERAL single-quoted strings into
#         ~/.bashrc so they expand at shell-load time, not install time.
# SC1091: /etc/os-release is sourced at runtime for ID/VERSION_CODENAME vars.
#
# Phase 9: in-VM dev stack for the headless work AI VM.
# RUNS INSIDE the Ubuntu 24.04 guest, not on the G7 host.
#
# Installs:
#   - uv (Python installer/manager) + Python 3.14
#   - fnm (Node manager) + Node 24 LTS + corepack + pnpm
#   - Claude Code CLI (Anthropic, npm global)
#   - Docker engine (official Docker apt repo)
#   - GitHub CLI (official gh apt repo)
#   - SOPS + age (pinned GitHub releases)
#   - direnv, starship, bash quality-of-life
#
# Cursor is NOT installed here — install Cursor on your Windows client and use
# Remote-SSH. Cursor auto-deploys its remote server into this VM on first connect.
#
# Run as your normal user, inside the VM. Idempotent / re-runnable.

set -euo pipefail

# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# Sanity: should be on Ubuntu 24.04. Warn (not fail) on mismatch.
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Detected ${PRETTY_NAME:-unknown OS}. This script targets Ubuntu 24.04 — proceeding anyway."
  fi
fi

# ---------------------------------------------------------------------------
# Pinned versions (bump as needed)
# ---------------------------------------------------------------------------
NODE_MAJOR="24"
PYTHON_VERSION="3.14"
SOPS_VERSION="v3.9.1"
AGE_VERSION="v1.2.1"

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

ensure_path() {
  local line="$1"
  local file="$HOME/.bashrc"
  if ! grep -Fqx "$line" "$file" 2>/dev/null; then
    printf '%s\n' "$line" >> "$file"
  fi
}

# Ensure ~/.local/bin is on PATH for this session and future ones.
case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) export PATH="$LOCAL_BIN:$PATH" ;; esac
ensure_path 'export PATH="$HOME/.local/bin:$PATH"'

# ---------------------------------------------------------------------------
log "Refreshing apt index"
sudo apt-get update -qq

log "Base packages (apt)"
sudo apt-get install -y -qq --no-install-recommends \
  curl ca-certificates gnupg lsb-release apt-transport-https \
  git build-essential pkg-config unzip jq htop tmux \
  ripgrep fd-find direnv \
  software-properties-common

# Ubuntu names fd 'fdfind' to avoid collision; add a shim.
if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
  ln -sf "$(command -v fdfind)" "$LOCAL_BIN/fd"
fi

# ---------------------------------------------------------------------------
# uv (Python installer/manager) + Python 3.14
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null; then
  log "Installing uv (Astral)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# uv installs to ~/.local/bin which is already on PATH
log "Installing Python $PYTHON_VERSION via uv"
uv python install "$PYTHON_VERSION"
uv python pin "$PYTHON_VERSION" 2>/dev/null || true   # pin globally if supported

# Shell completions
ensure_path 'eval "$(uv generate-shell-completion bash 2>/dev/null)"'

# ---------------------------------------------------------------------------
# fnm + Node LTS + corepack + pnpm
# ---------------------------------------------------------------------------
if ! command -v fnm >/dev/null; then
  log "Installing fnm (Fast Node Manager)"
  # --skip-shell: we add the eval line manually below to control placement.
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$HOME/.local/share/fnm" --skip-shell
  export PATH="$HOME/.local/share/fnm:$PATH"
fi

# Make fnm available in this shell session and in future ones.
ensure_path 'export PATH="$HOME/.local/share/fnm:$PATH"'
ensure_path 'eval "$(fnm env --use-on-cd --shell bash)"'
eval "$(fnm env --use-on-cd --shell bash)"

log "Installing Node $NODE_MAJOR LTS via fnm"
if ! fnm list | grep -qE "v${NODE_MAJOR}\."; then
  fnm install "$NODE_MAJOR"
fi
fnm default "$NODE_MAJOR"
fnm use "$NODE_MAJOR"

log "Enabling corepack (pnpm/yarn shim manager)"
corepack enable
corepack prepare pnpm@latest --activate

# ---------------------------------------------------------------------------
# Claude Code CLI (Anthropic)
# ---------------------------------------------------------------------------
if ! command -v claude >/dev/null; then
  log "Installing Claude Code CLI"
  npm install -g @anthropic-ai/claude-code
else
  log "Claude Code CLI already installed; upgrading"
  npm install -g @anthropic-ai/claude-code
fi

# ---------------------------------------------------------------------------
# Docker (official apt repo) — NOT Docker Desktop
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
  log "Installing Docker engine from official apt repo"
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

sudo systemctl enable --now docker
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
  warn "Added $USER to 'docker' group. Log out and back in (or 'newgrp docker') for it to take effect."
fi

# ---------------------------------------------------------------------------
# GitHub CLI (official apt repo)
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null; then
  log "Installing GitHub CLI from official apt repo"
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg status=none
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh
fi

# ---------------------------------------------------------------------------
# SOPS + age (pinned GitHub releases — apt versions lag)
# ---------------------------------------------------------------------------
ARCH_GO="$(dpkg --print-architecture)"   # amd64, arm64
case "$ARCH_GO" in
  amd64) AGE_ARCH="amd64"; SOPS_ARCH="amd64" ;;
  arm64) AGE_ARCH="arm64"; SOPS_ARCH="arm64" ;;
  *)     fail "Unsupported architecture for SOPS/age download: $ARCH_GO" ;;
esac

if ! command -v sops >/dev/null || [[ "$(sops --version 2>/dev/null | awk '{print $2}')" != "${SOPS_VERSION#v}" ]]; then
  log "Installing SOPS $SOPS_VERSION"
  curl -fLsS "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${SOPS_ARCH}" \
    -o /tmp/sops
  sudo install -m 0755 /tmp/sops /usr/local/bin/sops
  rm -f /tmp/sops
fi

if ! command -v age >/dev/null; then
  log "Installing age $AGE_VERSION"
  curl -fLsS "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${AGE_ARCH}.tar.gz" \
    -o /tmp/age.tar.gz
  tar -xzf /tmp/age.tar.gz -C /tmp
  sudo install -m 0755 /tmp/age/age /usr/local/bin/age
  sudo install -m 0755 /tmp/age/age-keygen /usr/local/bin/age-keygen
  rm -rf /tmp/age /tmp/age.tar.gz
fi

# ---------------------------------------------------------------------------
# starship prompt
# ---------------------------------------------------------------------------
if ! command -v starship >/dev/null; then
  log "Installing starship prompt"
  curl -sS https://starship.rs/install.sh \
    | sh -s -- --yes --bin-dir "$LOCAL_BIN"
fi
ensure_path 'eval "$(starship init bash)"'

# ---------------------------------------------------------------------------
# direnv hook
# ---------------------------------------------------------------------------
ensure_path 'eval "$(direnv hook bash)"'

# ---------------------------------------------------------------------------
log "Phase 9 complete."

cat <<EOF

Installed (inside this VM):

  uv      : $(uv --version 2>/dev/null || echo "(open new shell)")
  python  : $(uv run --python "$PYTHON_VERSION" python --version 2>/dev/null || echo "(open new shell; try: uv run python --version)")
  fnm     : $(fnm --version 2>/dev/null || echo "(open new shell)")
  node    : $(node --version 2>/dev/null || echo "(open new shell)")
  pnpm    : $(pnpm --version 2>/dev/null || echo "(open new shell)")
  claude  : $(claude --version 2>/dev/null | head -1 || echo "(open new shell)")
  docker  : $(docker --version 2>/dev/null || echo "(log out / in for group)")
  gh      : $(gh --version 2>/dev/null | head -1)
  sops    : $(sops --version 2>/dev/null | head -1)
  age     : $(age --version 2>/dev/null)
  direnv  : $(direnv --version 2>/dev/null)
  starship: $(starship --version 2>/dev/null | head -1)

Next steps:

  1. Open a fresh shell (or:  source ~/.bashrc) so PATH + shell hooks take effect.

  2. Docker group requires re-login. Quick test once active:
       docker run --rm hello-world

  3. Auth the CLIs:
       gh auth login
       claude login                 # or: claude auth login

  4. Per-project Python (uv):
       cd my-project
       uv init                      # or: uv venv
       uv add fastapi anthropic

  5. From your Windows laptop, install Cursor and connect via Remote-SSH
     to this VM (Tailscale handles the hostname). Cursor's server
     auto-deploys to ~/.cursor-server inside the VM on first connect.

  6. Verify everything is wired up:
       ./verify.sh                  # if present in this checkout

EOF
