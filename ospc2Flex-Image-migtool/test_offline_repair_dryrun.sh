#!/usr/bin/env bash
set -e
TESTDIR=/tmp/ospc2flex_dryrun_test
rm -rf $TESTDIR && mkdir -p $TESTDIR

create_test_image() {
  local name=$1 os_id=$2 ver=$3 has_netplan=$4
  local img=$TESTDIR/${name}.qcow2
  local mnt=$TESTDIR/mnt_${name}

  qemu-img create -f qcow2 "$img" 200M >/dev/null 2>&1
  sudo modprobe nbd max_part=8 2>/dev/null || true
  sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
  sleep 1
  sudo qemu-nbd --connect=/dev/nbd1 "$img"
  sleep 2
  echo -e "n\np\n1\n\n\nw" | sudo fdisk /dev/nbd1 >/dev/null 2>&1 || true
  sleep 1
  sudo mkfs.ext4 -F /dev/nbd1p1 >/dev/null 2>&1
  sudo mkdir -p "$mnt"
  sudo mount /dev/nbd1p1 "$mnt"

  sudo mkdir -p "$mnt/etc"
  echo "ID=$os_id" | sudo tee "$mnt/etc/os-release" >/dev/null
  echo "VERSION_ID=\"$ver\"" | sudo tee -a "$mnt/etc/os-release" >/dev/null
  echo "PRETTY_NAME=\"Test $os_id $ver\"" | sudo tee -a "$mnt/etc/os-release" >/dev/null

  if [ "$has_netplan" = "yes" ]; then
    sudo mkdir -p "$mnt/etc/netplan"
  fi
  if [ "$os_id" = "debian" ] && [ "$has_netplan" != "yes" ]; then
    sudo mkdir -p "$mnt/etc/network"
    echo "auto lo" | sudo tee "$mnt/etc/network/interfaces" >/dev/null
  fi
  if echo "$os_id" | grep -qE "almalinux|rocky|centos|rhel"; then
    sudo mkdir -p "$mnt/etc/sysconfig/network-scripts"
  fi

  echo "/ ext4 defaults 0 1" | sudo tee "$mnt/etc/fstab" >/dev/null

  sudo umount "$mnt"
  sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
  sleep 1
  echo "  Created: $name ($os_id $ver netplan=$has_netplan)"
}

echo "Creating mock test images..."
create_test_image u20test ubuntu 20.04 yes
create_test_image u22test ubuntu 22.04 yes
create_test_image u24test ubuntu 24.04 yes
create_test_image d10test debian 10.13 no
create_test_image d11test debian 11.8 no
create_test_image d12test debian 12.4 yes
create_test_image a8test almalinux 8.9 no
create_test_image a9test almalinux 9.3 no
create_test_image c7test centos 7.9 no
create_test_image c8test centos 8.5 no
create_test_image c9test centos 9.2 no
create_test_image r7test rhel 7.9 no
create_test_image r8test rhel 8.10 no
create_test_image r9test rhel 9.4 no

echo ""
echo "============================================================"
echo "  DRY-RUN TESTS"
echo "============================================================"

for img in u20test u22test u24test d10test d11test d12test a8test a9test c7test c8test c9test r7test r8test r9test; do
  echo ""
  echo "=== $img ==="
  sudo bash /tmp/ospc2flex_offline_repair.sh --qcow2 "$TESTDIR/${img}.qcow2" --dry-run 2>&1 | grep -E "OS detected|Repair profile|Network|DRY-RUN|netplan|ifcfg|keyfile|NM|COMPLETE|FAILED" || echo "  (no matching output)"
done

echo ""
echo "============================================================"
echo "  ALL TESTS COMPLETE"
echo "============================================================"
rm -rf $TESTDIR
