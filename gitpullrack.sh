cat > gitpullrack.sh <<'EOF'
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

# Prevent accidental loss of uncommitted work.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: You have uncommitted changes."
    echo "Commit or stash them before pulling."
    git status --short
    exit 1
fi

echo "Fetching rackerlabs/$TARGET_BRANCH..."
git fetch rackerlabs "$TARGET_BRANCH"

if [[ "${1:-}" == "--reset" ]]; then
    BACKUP_BRANCH="backup-before-rack-pull-$(date +%Y%m%d-%H%M%S)"
    git branch "$BACKUP_BRANCH"

    echo "Backup created: $BACKUP_BRANCH"
    echo "Resetting local branch to rackerlabs/$TARGET_BRANCH..."
    git reset --hard "rackerlabs/$TARGET_BRANCH"
else
    echo "Rebasing local branch onto rackerlabs/$TARGET_BRANCH..."
    git rebase "rackerlabs/$TARGET_BRANCH"
fi

echo "Local repository updated from $RACK_REPO"
git status --short --branch
EOF

chmod +x gitpullrack.sh

