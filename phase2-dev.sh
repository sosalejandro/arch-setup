#!/usr/bin/env bash
# Phase 2: developer tooling
# Run ON THE G7 over SSH, after Phase 1 succeeded and SSH from Windows is confirmed.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "Installing dev essentials"
sudo pacman -S --needed --noconfirm \
  git base-devel neovim htop fastfetch wget curl unzip zip ripgrep fd \
  fnm

# ---------------------------------------------------------------------------
log "Configuring fnm in shell rc files (idempotent)"
FNM_LINE='eval "$(fnm env --use-on-cd --shell bash)"'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  if ! grep -Fq 'fnm env' "$rc"; then
    printf '\n# fnm (Node.js version manager)\n%s\n' "$FNM_LINE" >> "$rc"
  fi
done

# Load fnm into THIS shell so the rest of the script can use it
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Installing latest LTS Node.js via fnm"
fnm install --lts
fnm default lts-latest
fnm use lts-latest

NODE_VERSION="$(node --version)"
log "Node ready: ${NODE_VERSION}"

# ---------------------------------------------------------------------------
log "Installing Claude Code globally via npm"
npm install -g @anthropic-ai/claude-code

# ---------------------------------------------------------------------------
log "Phase 2 complete."

cat <<EOF

Verify:
  node --version       => should print ${NODE_VERSION}
  claude --version     => should print a Claude Code version

You may need to open a new SSH session for fnm to be auto-loaded by .bashrc.

Optional next:
  ./phase3-harden.sh    (SSH password-auth off, ufw firewall)

Recommended manual step (do once SSH key auth works):
  On Windows main laptop:
    ssh-keygen -t ed25519
    type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh ${USER}@g7.local "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

  Next SSH connection should be passwordless. Then it's safe to run phase3-harden.sh.

EOF
