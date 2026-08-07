eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa
./run_origin_rsync_interactive.sh
