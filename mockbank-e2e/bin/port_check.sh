#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
echo "--- who listens on 3000/3001/2222:"
ss -ltnp 2>/dev/null | grep -E ':(3000|3001|2222)\s' || echo "(nothing visible from WSL — may be a Windows-side listener)"
echo "--- docker containers:"
docker ps -a --format '{{.Names}}  {{.Ports}}  {{.Status}}' | head -10
echo "--- gitea up help:"
opencenter-local gitea up --help 2>&1 | sed -n '1,30p'
