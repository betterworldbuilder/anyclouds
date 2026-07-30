#!/usr/bin/env bash
for t in docker kind kubectl flux helm opencenter git python3 node curl jq; do
  if command -v "$t" >/dev/null 2>&1; then
    v=$("$t" --version 2>/dev/null | head -1)
    echo "OK      $t : ${v:-installed}"
  else
    echo "MISSING $t"
  fi
done
echo "---"
if docker info >/dev/null 2>&1; then echo "docker daemon: RUNNING"; else echo "docker daemon: NOT RUNNING"; fi
echo "---"
free -h | head -2
df -h / | tail -1
