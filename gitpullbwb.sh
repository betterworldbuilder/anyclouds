#!/usr/bin/env bash
set -euo pipefail

REPO="git@github.com:betterworldbuilder/cloudmaxNew.git"
REMOTE="betterworldbuilder"
BRANCH="main"
SSH_KEY="${HOME}/.ssh/id_ed25519_bwb"

cd "$(git rev-parse --show-toplevel)"

[[ -f "$SSH_KEY" ]] || {
    echo "ERROR: SSH key not found: $SSH_KEY"
    exit 1
}

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

if git remote get-url "$REMOTE" >/dev/null 2>&1; then
    git remote set-url "$REMOTE" "$REPO"
else
    git remote add "$REMOTE" "$REPO"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: You have uncommitted changes."
    echo "Commit or stash them before pulling."
    git status --short
    exit 1
fi

echo "Fetching $REMOTE/$BRANCH..."
git fetch "$REMOTE" "$BRANCH"

if [[ "${1:-}" == "--reset" ]]; then
    BACKUP_BRANCH="backup-before-bwb-pull-$(date +%Y%m%d-%H%M%S)"
    git branch "$BACKUP_BRANCH"

    echo "Backup created: $BACKUP_BRANCH"
    git reset --hard "$REMOTE/$BRANCH"
else
    git rebase "$REMOTE/$BRANCH"
fi

echo "Pull completed from: $REPO"
git status --short --branch
