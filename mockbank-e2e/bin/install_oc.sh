#!/usr/bin/env bash
# Install the real OpenCenter CLI from source (docs.opencenter.dev getting-started).
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
step() { echo; echo "===== $* ====="; }

step "1/5 mise (tool manager)"
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh || { echo "[FAIL] mise install"; exit 1; }
  export PATH="$HOME/.local/bin:$PATH"
fi
mise --version || exit 1

step "2/5 clone openCenter-cli"
REPO_DIR="$HOME/openCenter-cli"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only 2>&1 | tail -1
else
  git clone --depth 1 https://github.com/opencenter-cloud/openCenter-cli.git "$REPO_DIR" \
    || { echo "[FAIL] clone github.com/opencenter-cloud/openCenter-cli"; exit 2; }
fi
ls "$REPO_DIR" | head

step "3/5 mise trust + install project tools"
cd "$REPO_DIR" || exit 1
mise trust 2>&1 | tail -1
mise install 2>&1 | tail -5 || { echo "[FAIL] mise install"; exit 3; }

step "4/5 build"
mise run build 2>&1 | tail -10 || { echo "[FAIL] mise run build"; exit 4; }
ls -la ./bin/opencenter || exit 4

step "5/5 install binary (replaces mock shim in ~/.local/bin)"
if [ -f "$HOME/.local/bin/opencenter" ]; then
  cp "$HOME/.local/bin/opencenter" "$HOME/.local/bin/opencenter.mock-shim.bak"
  echo "mock shim backed up to ~/.local/bin/opencenter.mock-shim.bak"
fi
install -m 755 ./bin/opencenter "$HOME/.local/bin/opencenter"
hash -r
opencenter version && echo "INSTALL OK: $(command -v opencenter)"
