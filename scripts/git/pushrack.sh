#!/usr/bin/env bash
set -euo pipefail

RACK_REPO="git@github.com:rackerlabs/OSPC2FLEX-Cloud-Jumper.git"
SSH_KEY="${HOME}/.ssh/id_ed25519_bwb"
TARGET_BRANCH="main"

cd "$(git rev-parse --show-toplevel)"

if [[ ! -f "$SSH_KEY" ]]; then
    echo "ERROR: SSH key not found: $SSH_KEY"
    exit 1
fi

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes"

# Create or correct the Rackspace remote.
if git remote get-url rackerlabs >/dev/null 2>&1; then
    git remote set-url rackerlabs "$RACK_REPO"
else
    git remote add rackerlabs "$RACK_REPO"
fi

# Save all current changes.
git add -A

if ! git diff --cached --quiet; then
    git commit -m "Sync latest Cloud Jumper changes"
else
    echo "No uncommitted changes to commit."
fi

echo "Pushing $(git branch --show-current) to rackerlabs/$TARGET_BRANCH..."

if [[ "${1:-}" == "--force" ]]; then
    git fetch rackerlabs "$TARGET_BRANCH" || true
    git push --force-with-lease rackerlabs HEAD:"$TARGET_BRANCH"
else
    git push -u rackerlabs HEAD:"$TARGET_BRANCH"
fi

echo "Successfully pushed to $RACK_REPO"
