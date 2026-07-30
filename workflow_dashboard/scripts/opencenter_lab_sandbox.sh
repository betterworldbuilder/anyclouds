#!/usr/bin/env bash
set -euo pipefail

rootfs="$1"
lab_home="$2"
server_home="$3"
project_scripts="$4"
command_text="$5"

mount --make-rprivate /

mkdir -p \
  "$rootfs/usr" \
  "$rootfs/etc" \
  "$rootfs/proc" \
  "$rootfs/dev" \
  "$rootfs/tmp" \
  "$rootfs/home/opencenter-learner" \
  "$rootfs/opt/cloudmax-scripts"

mount --bind /usr "$rootfs/usr"
mount -o remount,bind,ro "$rootfs/usr"
mount --bind /etc "$rootfs/etc"
mount -o remount,bind,ro "$rootfs/etc"

server_local="$server_home/.local"
if [[ -d "$server_local" ]]; then
  mkdir -p "$rootfs$server_local"
  mount --bind "$server_local" "$rootfs$server_local"
  mount -o remount,bind,ro "$rootfs$server_local"
fi

if [[ -d "$project_scripts" ]]; then
  mount --bind "$project_scripts" "$rootfs/opt/cloudmax-scripts"
  mount -o remount,bind,ro "$rootfs/opt/cloudmax-scripts"
fi

mount --bind "$lab_home" "$rootfs/home/opencenter-learner"
chmod 0700 "$lab_home"
chmod 1777 "$rootfs/tmp"

for device in null zero random urandom; do
  touch "$rootfs/dev/$device"
  mount --bind "/dev/$device" "$rootfs/dev/$device"
done
mount -t proc proc "$rootfs/proc"

ln -sfn usr/bin "$rootfs/bin"
ln -sfn usr/lib "$rootfs/lib"
if [[ -d /usr/lib64 ]]; then
  ln -sfn usr/lib64 "$rootfs/lib64"
fi

path_value="/home/opencenter-learner/.local/bin:$server_local/bin:/opt/cloudmax-scripts:/usr/local/bin:/usr/bin:/bin"
exec chroot "$rootfs" /usr/bin/env -i \
  HOME=/home/opencenter-learner \
  USER=opencenter-learner \
  LOGNAME=opencenter-learner \
  SHELL=/bin/bash \
  LANG=C.UTF-8 \
  PATH="$path_value" \
  /bin/bash --noprofile --norc -lc "$command_text"
