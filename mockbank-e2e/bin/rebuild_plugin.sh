#!/usr/bin/env bash
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/openCenter-cli" || exit 1
mise run build-local-plugin 2>&1 | tail -3 || { echo FAIL-build; exit 1; }
install -m 755 ./bin/opencenter-local "$HOME/.local/bin/opencenter-local"
# clean up the failed container + plugin state so 'gitea up' starts fresh
docker rm -f gitea >/dev/null 2>&1
rm -rf "$HOME/.config/opencenter/local"
echo "plugin rebuilt + state cleaned"
