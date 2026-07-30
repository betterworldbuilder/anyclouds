#!/usr/bin/env bash
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/openCenter-cli" || exit 1
mise run build 2>&1 | tail -4 || { echo FAIL-build; exit 1; }
install -m 755 ./bin/opencenter "$HOME/.local/bin/opencenter"
install -m 755 ./bin/opencenter-local "$HOME/.local/bin/opencenter-local"
opencenter version | head -2
echo "--- resume deploy from gitea-attach-kind:"
opencenter cluster deploy mockbank-org/mockbank --container-runtime docker --from-step gitea-attach-kind
