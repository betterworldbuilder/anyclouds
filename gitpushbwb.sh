#!/usr/bin/env bash
set -euo pipefail

REPO="git@github.com:betterworldbuilder/cloudmaxNew.git"
SSH_KEY="$HOME/.ssh/id_ed25519_bwb"
BRANCH="main"

cd "$(git rev-parse --show-toplevel)"

git add -A
git diff --cached --quiet || git commit -m "Sync latest Cloud Jumper changes"

GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes" \
git push "$REPO" HEAD:"$BRANCH"
