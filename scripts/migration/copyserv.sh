eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa
# Sibling script — resolve next to this file so the caller's cwd does not matter.
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_origin_rsync_interactive.sh"
