#!/usr/bin/env bash
echo "--- existing openCenter-cli checkouts:"
for d in "$HOME" "$HOME/cloudmax" "$HOME/OSPC2FLEX" "$HOME/src" "$HOME/git"; do
  [ -d "$d" ] && find "$d" -maxdepth 3 -iname "*opencenter*cli*" -type d 2>/dev/null
done | head -10
echo "--- mise:"
command -v mise >/dev/null 2>&1 && mise --version || echo "mise not installed"
echo "--- go toolchain (fallback build):"
command -v go >/dev/null 2>&1 && go version || echo "go not installed"
echo "--- current opencenter on PATH:"
command -v opencenter && opencenter version 2>/dev/null | head -2
echo "--- ~/.local/bin listing:"
ls -la "$HOME/.local/bin" 2>/dev/null | head -10
