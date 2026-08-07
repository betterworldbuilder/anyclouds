#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo " SuperSizeVolume.sh"
echo " Remote FLEX / OpenStack Big Volume Builder"
echo " With Full System Disk Scan"
echo "=================================================="
echo
echo "This script SSHs into a target VM, scans ALL disks,"
echo "including the OS/system disk, then combines selected"
echo "safe data disks into one large LVM logical volume."
echo
echo "IMPORTANT:"
echo "  The system/root disk is scanned and displayed,"
echo "  but the script will refuse to use it for LVM."
echo

echo "=================================================="
echo " How it works"
echo "=================================================="
echo
echo "1. You run this script from your jumphost/admin VM."
echo "2. It asks for the target VM IP."
echo "3. It SSHs into the target VM."
echo "4. It scans ALL disks, including:"
echo "   - OS/root disk"
echo "   - boot partitions"
echo "   - EFI partition"
echo "   - swap"
echo "   - mounted data disks"
echo "   - free/unmounted disks"
echo "   - existing LVM disks"
echo "5. It shows which disks are SAFE candidates."
echo "6. You choose only the data disks to combine."
echo "7. It creates one LVM logical volume."
echo "8. It formats it as XFS and mounts it."
echo "9. It adds it to /etc/fstab by UUID."
echo
echo "WARNING:"
echo "  Selected disks will be erased."
echo "  Do not select the OS disk."
echo "  The script also blocks OS/root disk selection."
echo

read -rp "Target server IP: " TARGET_IP

if [[ -z "$TARGET_IP" ]]; then
  echo "ERROR: Target server IP cannot be empty."
  exit 1
fi

read -rp "SSH user [ubuntu]: " SSH_USER
SSH_USER="${SSH_USER:-ubuntu}"

read -rp "SSH port [22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

read -rp "Mount point on target [/data]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-/data}"

read -rp "Volume group name [vg_bigdata]: " VG_NAME
VG_NAME="${VG_NAME:-vg_bigdata}"

read -rp "Logical volume name [lv_bigdata]: " LV_NAME
LV_NAME="${LV_NAME:-lv_bigdata}"

read -rp "New logical volume size [100%FREE]: " LV_SIZE
LV_SIZE="${LV_SIZE:-100%FREE}"

echo
echo "Requested logical volume size: $LV_SIZE"
echo "Examples: 500G, 1T, 2T, 2.5T, 100%FREE"
echo

echo
echo "Testing SSH connection to ${SSH_USER}@${TARGET_IP}:${SSH_PORT} ..."
ssh -p "$SSH_PORT" \
  -o BatchMode=no \
  -o ConnectTimeout=10 \
  "${SSH_USER}@${TARGET_IP}" "echo SSH_OK"

echo
echo "=================================================="
echo " Full target disk scan before selection"
echo "=================================================="

ssh -p "$SSH_PORT" "${SSH_USER}@${TARGET_IP}" 'bash -s' <<'REMOTE_SCAN'
set -euo pipefail

echo
echo "=== ROOT FILESYSTEM ==="
findmnt /

ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
ROOT_DISK=""

if [[ -n "$ROOT_SOURCE" ]]; then
  ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"
fi

echo
echo "Detected root source: ${ROOT_SOURCE:-unknown}"
echo "Detected root disk:   ${ROOT_DISK:-unknown}"

echo
echo "=== ALL BLOCK DEVICES ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL

echo
echo "=== FILESYSTEM USAGE ==="
df -hT

echo
echo "=== SWAP ==="
swapon --show || true

echo
echo "=== EXISTING LVM PHYSICAL VOLUMES ==="
sudo pvs -o pv_name,vg_name,pv_size,pv_free,pv_used,pv_attr 2>/dev/null || echo "No LVM physical volumes found."

echo
echo "=== EXISTING LVM VOLUME GROUPS ==="
sudo vgs -o vg_name,vg_size,vg_free,lv_count,pv_count,vg_attr 2>/dev/null || echo "No LVM volume groups found."

echo
echo "=== EXISTING LVM LOGICAL VOLUMES ==="
sudo lvs -a -o lv_name,vg_name,lv_size,lv_attr,devices 2>/dev/null || echo "No LVM logical volumes found."

echo
echo "=== DISK SAFETY CLASSIFICATION ==="
printf "%-12s %-10s %-12s %-20s %-12s\n" "DISK" "SIZE" "TYPE" "STATUS" "REASON"
printf "%-12s %-10s %-12s %-20s %-12s\n" "----" "----" "----" "------" "------"

while read -r NAME SIZE TYPE FSTYPE MOUNTPOINTS; do
  [[ "$TYPE" != "disk" ]] && continue

  DEV="/dev/$NAME"
  STATUS="CANDIDATE"
  REASON="unmounted-data-disk"

  if [[ -n "$ROOT_DISK" && "$NAME" == "$ROOT_DISK" ]]; then
    STATUS="PROTECTED"
    REASON="root-os-disk"
  elif lsblk -nr "$DEV" -o MOUNTPOINTS | grep -q '/'; then
    STATUS="PROTECTED"
    REASON="mounted-disk"
  elif lsblk -nr "$DEV" -o FSTYPE | grep -q 'swap'; then
    STATUS="PROTECTED"
    REASON="swap-disk"
  elif sudo pvs "$DEV" >/dev/null 2>&1; then
    STATUS="PROTECTED"
    REASON="existing-lvm-pv"
  fi

  printf "%-12s %-10s %-12s %-20s %-12s\n" "$DEV" "$SIZE" "$TYPE" "$STATUS" "$REASON"
done < <(lsblk -nr -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS)

echo
echo "Only disks marked CANDIDATE should be selected."
REMOTE_SCAN

echo
echo "Example:"
echo "  vdd vde"
echo
read -rp "Enter target disk names to combine: " DISK_INPUT

if [[ -z "$DISK_INPUT" ]]; then
  echo "ERROR: No disks selected. Exiting."
  exit 1
fi

SELECTED_DISKS=()

for d in $DISK_INPUT; do
  clean_disk="${d#/dev/}"
  SELECTED_DISKS+=("$clean_disk")
done

echo
echo "You selected disks on target:"
for d in "${SELECTED_DISKS[@]}"; do
  echo "  /dev/$d"
done

echo
echo "Requested logical volume size: $LV_SIZE"
echo
echo "WARNING: This will erase all data on the selected target disks."
echo "The OS/root disk is protected and will be refused by the remote script."
echo
read -rp "Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Cancelled."
  exit 1
fi

REMOTE_SCRIPT="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

VG_NAME="$1"
LV_NAME="$2"
MOUNT_POINT="$3"
LV_SIZE="$4"
shift 4
DISKS=("$@")

FS_TYPE="xfs"

echo "=================================================="
echo " Running SuperSizeVolume on target server"
echo "=================================================="

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This remote script must run with sudo/root."
  exit 1
fi

if [[ ${#DISKS[@]} -eq 0 ]]; then
  echo "ERROR: No disks were passed to the remote script."
  exit 1
fi

echo
echo "Checking required packages..."

MISSING_TOOLS=()

if ! command -v pvcreate >/dev/null 2>&1; then
  MISSING_TOOLS+=("lvm2")
fi

if ! command -v mkfs.xfs >/dev/null 2>&1; then
  MISSING_TOOLS+=("xfsprogs")
fi

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
  echo "Required tools are already installed."
else
  echo "Missing packages: ${MISSING_TOOLS[*]}"
  echo "Installing required packages..."

  if command -v apt-get >/dev/null 2>&1; then
    if ! apt-get update; then
      echo
      echo "ERROR: apt-get update failed."
      echo "This is usually caused by a broken APT repository."
      echo
      echo "Find bad repos with:"
      echo "  sudo grep -R \"rax.mirror.rackspace.com\" /etc/apt/sources.list /etc/apt/sources.list.d/ || true"
      echo
      echo "Disable the bad Rackspace mirror repo with:"
      echo "  sudo sed -i.bak '/rax.mirror.rackspace.com/s/^/# DISABLED_BAD_SIGNATURE /' /etc/apt/sources.list"
      echo "  sudo find /etc/apt/sources.list.d -type f -name \"*.list\" -exec sudo sed -i.bak '/rax.mirror.rackspace.com/s/^/# DISABLED_BAD_SIGNATURE /' {} \\;"
      echo "  sudo apt-get clean"
      echo "  sudo apt-get update"
      echo
      echo "Then rerun this script."
      exit 1
    fi

    apt-get install -y "${MISSING_TOOLS[@]}"

  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${MISSING_TOOLS[@]}"

  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${MISSING_TOOLS[@]}"

  else
    echo "ERROR: Unsupported OS package manager."
    echo "Please install manually:"
    echo "  lvm2 xfsprogs"
    exit 1
  fi
fi

echo
echo "=================================================="
echo " Full system disk scan before creation"
echo "=================================================="

echo
echo "Root filesystem:"
findmnt /

ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
ROOT_DISK=""

if [[ -n "$ROOT_SOURCE" ]]; then
  ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"
fi

echo
echo "Detected root source: ${ROOT_SOURCE:-unknown}"
echo "Detected root disk:   ${ROOT_DISK:-unknown}"

echo
echo "All block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL

echo
echo "Filesystem usage:"
df -hT

echo
echo "Swap:"
swapon --show || true

echo
echo "Existing LVM physical volumes:"
pvs -o pv_name,vg_name,pv_size,pv_free,pv_used,pv_attr 2>/dev/null || true

echo
echo "Existing LVM volume groups:"
vgs -o vg_name,vg_size,vg_free,lv_count,pv_count,vg_attr 2>/dev/null || true

echo
echo "Existing LVM logical volumes:"
lvs -a -o lv_name,vg_name,lv_size,lv_attr,devices 2>/dev/null || true

SELECTED_DEVS=()

for DISK in "${DISKS[@]}"; do
  DISK="${DISK#/dev/}"
  DEV="/dev/$DISK"

  echo
  echo "Checking selected disk $DEV ..."

  if [[ ! -b "$DEV" ]]; then
    echo "ERROR: $DEV does not exist."
    exit 1
  fi

  DEV_TYPE="$(lsblk -dn -o TYPE "$DEV")"

  if [[ "$DEV_TYPE" != "disk" ]]; then
    echo "ERROR: $DEV is not a whole disk. Type detected: $DEV_TYPE"
    echo "Use whole disks such as /dev/vdb, /dev/vdc, /dev/vdd."
    exit 1
  fi

  if [[ -n "$ROOT_DISK" && "$DISK" == "$ROOT_DISK" ]]; then
    echo "ERROR: $DEV is the root OS disk. Refusing."
    exit 1
  fi

  if lsblk -nr "$DEV" -o MOUNTPOINTS | grep -q '/'; then
    echo "ERROR: $DEV or one of its partitions is already mounted. Refusing."
    exit 1
  fi

  if lsblk -nr "$DEV" -o FSTYPE | grep -q 'swap'; then
    echo "ERROR: $DEV is used for swap. Refusing."
    exit 1
  fi

  if pvs "$DEV" >/dev/null 2>&1; then
    echo "ERROR: $DEV is already an LVM physical volume. Refusing."
    exit 1
  fi

  SELECTED_DEVS+=("$DEV")
done

echo
echo "Selected safe data devices:"
printf '  %s\n' "${SELECTED_DEVS[@]}"

TOTAL_BYTES=0

for DEV in "${SELECTED_DEVS[@]}"; do
  SIZE_BYTES="$(blockdev --getsize64 "$DEV")"
  TOTAL_BYTES=$((TOTAL_BYTES + SIZE_BYTES))
done

TOTAL_GB="$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES/1000/1000/1000}")"
TOTAL_TB="$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES/1000/1000/1000/1000}")"

echo
echo "Approximate combined raw size: ${TOTAL_GB} GB / ${TOTAL_TB} TB"
echo "Requested logical volume size: $LV_SIZE"

if vgs "$VG_NAME" >/dev/null 2>&1; then
  echo "ERROR: Volume group $VG_NAME already exists."
  echo "Choose another VG name or remove the old VG manually."
  exit 1
fi

echo
echo "Wiping old filesystem signatures from selected disks..."

for DEV in "${SELECTED_DEVS[@]}"; do
  wipefs -a "$DEV"
done

echo
echo "Creating LVM physical volumes..."
pvcreate -ff -y "${SELECTED_DEVS[@]}"

echo
echo "Creating volume group: $VG_NAME"
vgcreate "$VG_NAME" "${SELECTED_DEVS[@]}"

echo
echo "Volume group capacity:"
vgs "$VG_NAME"

echo
echo "Creating logical volume: $LV_NAME"
echo "Requested size: $LV_SIZE"

if [[ "$LV_SIZE" == "100%FREE" ]]; then
  lvcreate -n "$LV_NAME" -l 100%FREE "$VG_NAME"
else
  lvcreate -n "$LV_NAME" -L "$LV_SIZE" "$VG_NAME"
fi

LV_PATH="/dev/${VG_NAME}/${LV_NAME}"

echo
echo "Formatting $LV_PATH as XFS..."
mkfs.xfs -f "$LV_PATH"

echo
echo "Creating mount point: $MOUNT_POINT"
mkdir -p "$MOUNT_POINT"

echo
echo "Mounting volume..."
mount "$LV_PATH" "$MOUNT_POINT"

UUID="$(blkid -s UUID -o value "$LV_PATH")"

if [[ -z "$UUID" ]]; then
  echo "ERROR: Could not detect UUID for $LV_PATH."
  exit 1
fi

echo
echo "Backing up /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"

if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT $FS_TYPE defaults,nofail 0 2" >> /etc/fstab
fi

echo
echo "Testing /etc/fstab..."
mount -a

echo
echo "=================================================="
echo " SuperSizeVolume completed successfully"
echo "=================================================="

echo
echo "=================================================="
echo " All disks / volumes after creation"
echo "=================================================="

echo
echo "Block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL

echo
echo "Filesystem usage:"
df -hT

echo
echo "Swap:"
swapon --show || true

echo
echo "LVM physical volumes:"
pvs -o pv_name,vg_name,pv_size,pv_free,pv_used,pv_attr

echo
echo "LVM volume groups:"
vgs -o vg_name,vg_size,vg_free,lv_count,pv_count,vg_attr

echo
echo "All LVM logical volumes:"
lvs -a -o lv_name,vg_name,lv_size,lv_attr,origin,pool_lv,data_percent,metadata_percent,devices

echo
echo "=================================================="
echo " Newly created SuperSize volume"
echo "=================================================="
echo
echo "Logical volume path: $LV_PATH"
echo "Volume group:        $VG_NAME"
echo "Logical volume name: $LV_NAME"
echo "Requested size:      $LV_SIZE"
echo "Filesystem:          $FS_TYPE"
echo "Mount point:         $MOUNT_POINT"
echo "UUID:                $UUID"

echo
echo "New volume filesystem usage:"
df -hT "$MOUNT_POINT"

echo
echo "New volume block detail:"
lsblk "$LV_PATH" -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS

echo
echo "Reminder:"
echo "This is capacity aggregation using LVM, not redundancy."
echo "If one selected Cinder disk fails, the full filesystem may be affected."
EOF
)"

echo
echo "Creating big volume remotely on ${TARGET_IP}..."

ssh -p "$SSH_PORT" "${SSH_USER}@${TARGET_IP}" \
  "sudo bash -s -- '$VG_NAME' '$LV_NAME' '$MOUNT_POINT' '$LV_SIZE' ${SELECTED_DISKS[*]}" <<< "$REMOTE_SCRIPT"

echo
echo "=================================================="
echo " Done"
echo "=================================================="
echo
echo "Verify with:"
echo "ssh -p $SSH_PORT ${SSH_USER}@${TARGET_IP} \"df -hT $MOUNT_POINT && lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS && sudo pvs && sudo vgs && sudo lvs -a -o lv_name,vg_name,lv_size,devices\""
echo

