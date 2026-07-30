#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
echo "--- opencenter --help:"
opencenter --help 2>&1 | head -30
echo "--- opencenter cluster --help:"
opencenter cluster --help 2>&1 | head -30
echo "--- repo bin:"
ls -la "$HOME/openCenter-cli/bin/"
echo "--- opencenter-local help:"
"$HOME/openCenter-cli/bin/opencenter-local" --help 2>&1 | head -20
