#!/usr/bin/env bash
# Phase 5: programming languages and language-adjacent tooling.
# Go, Rust, Scala 3, Python (system + pyenv), .NET, TypeScript, pnpm, Taskfile.
#
# Run as your normal user, over SSH. Idempotent / re-runnable.

set -euo pipefail

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && fail "Do not run as root."

# ---------------------------------------------------------------------------
log "Go (latest stable from extra)"
sudo pacman -S --needed --noconfirm go

# Add GOPATH/bin and GOBIN to PATH if not already
if ! grep -q 'GOPATH' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# Go
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"
EOF
fi

# ---------------------------------------------------------------------------
log "Rust via rustup (toolchain manager — preferred over the 'rust' package)"
sudo pacman -S --needed --noconfirm rustup
# Install default stable toolchain if no toolchain is set
if ! rustup show active-toolchain >/dev/null 2>&1; then
  rustup default stable
fi
rustup component add rust-analyzer clippy rustfmt 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Python (system) + pyenv (multi-version, optional via AUR)"
sudo pacman -S --needed --noconfirm python python-pip python-pipx
# pyenv from AUR — handy when projects pin specific Python versions
yay -S --needed --noconfirm pyenv
# Add pyenv init to .bashrc if not already
if ! grep -q 'pyenv init' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - 2>/dev/null || true)"
EOF
fi

# ---------------------------------------------------------------------------
log ".NET SDK (current — installs latest from extra)"
# The 'dotnet-sdk' package tracks the latest release.
# dotnet-sdk-8.0 and dotnet-sdk-9.0 are also available for pinning specific LTS / current.
sudo pacman -S --needed --noconfirm dotnet-sdk aspnet-runtime

# ---------------------------------------------------------------------------
log "Node toolchain extras (TypeScript, pnpm, Taskfile)"
# pnpm via the official package — independent of npm, no nvm interaction issues
sudo pacman -S --needed --noconfirm pnpm go-task

# TypeScript via npm global (needs fnm-managed node from phase2)
if command -v node >/dev/null 2>&1; then
  npm install -g typescript ts-node
else
  warn "node not on PATH. Open a new shell (so fnm loads), then run: npm install -g typescript ts-node"
fi

# ---------------------------------------------------------------------------
log "Scala 3 via Coursier (cs) — AUR"
# Coursier is the canonical Scala 3 installer/manager. Not in official repos.
yay -S --needed --noconfirm coursier
# 'cs setup' installs Scala 3, scala-cli, sbt, and friends into ~/.local/share/coursier.
# --yes accepts defaults, including PATH updates (writes to ~/.profile / ~/.bashrc).
cs setup --yes 2>&1 | tail -20 || warn "cs setup did not run cleanly; you can retry manually: 'cs setup'"

# ---------------------------------------------------------------------------
log "Phase 5 complete."

cat <<EOF

Installed:
  - Go      : $(go version 2>/dev/null || echo "(open new shell)")
  - Rust    : $(rustc --version 2>/dev/null || echo "(open new shell)")
  - Python  : $(python --version 2>/dev/null)
  - .NET    : $(dotnet --version 2>/dev/null || echo "(open new shell)")
  - pnpm    : $(pnpm --version 2>/dev/null || echo "(open new shell)")
  - task    : $(task --version 2>/dev/null || echo "(go-task installed; binary name 'task')")
  - Scala   : run 'cs install scala' after re-opening your shell

Re-open your SSH session (or 'source ~/.bashrc') so PATH updates take effect.

To pin Python versions per-project: 'pyenv install 3.13.1' then 'pyenv local 3.13.1'.

EOF
