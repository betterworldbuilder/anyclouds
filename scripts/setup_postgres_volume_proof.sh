#!/usr/bin/env bash
set -Eeuo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/pgdata}"
DB_NAME="${DB_NAME:-openstack_drinks}"
TABLE_NAME="${TABLE_NAME:-preferred_drinks}"
DEVICE="${DEVICE:-}"
FORCE_FORMAT="${FORCE_FORMAT:-false}"

log() {
  echo "[PGVOL] $*"
}

die() {
  echo "[PGVOL][ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root or with sudo."
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y postgresql postgresql-contrib util-linux e2fsprogs coreutils
  else
    die "This script currently supports Debian/Ubuntu apt-based systems."
  fi
}

show_disks() {
  log "Current block devices:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
}

is_root_or_system_disk() {
  local dev="$1"
  local base
  base="$(basename "$dev")"

  case "$base" in
    sda|vda|xvda|nvme0n1)
      return 0
      ;;
  esac

  if findmnt -n -o SOURCE / | grep -q "$dev"; then
    return 0
  fi

  return 1
}

detect_device() {
  if [[ -n "$DEVICE" ]]; then
    [[ -b "$DEVICE" ]] || die "Provided DEVICE does not exist or is not a block device: $DEVICE"
    if is_root_or_system_disk "$DEVICE"; then
      die "Refusing to use root/system disk: $DEVICE"
    fi
    echo "$DEVICE"
    return 0
  fi

  local candidate=""
  while read -r name type fstype mountpoint; do
    local dev="/dev/$name"

    [[ "$type" == "disk" ]] || continue
    [[ -z "$mountpoint" || "$mountpoint" == "-" ]] || continue

    if is_root_or_system_disk "$dev"; then
      continue
    fi

    # Prefer disks with no filesystem.
    if [[ -z "$fstype" || "$fstype" == "-" ]]; then
      candidate="$dev"
      break
    fi
  done < <(lsblk -ndo NAME,TYPE,FSTYPE,MOUNTPOINT)

  [[ -n "$candidate" ]] || {
    show_disks
    die "No safe unmounted non-root disk without filesystem was found. Re-run with DEVICE=/dev/vdb if you know the correct disk."
  }

  echo "$candidate"
}

format_if_needed() {
  local dev="$1"
  local fstype

  fstype="$(lsblk -ndo FSTYPE "$dev" | head -n1 || true)"

  if [[ -n "$fstype" ]]; then
    log "$dev already has filesystem: $fstype. Not formatting."
    return 0
  fi

  if [[ "$FORCE_FORMAT" != "true" && -n "$(lsblk -nr "$dev" | awk 'NR>1 {print}')" ]]; then
    die "$dev appears to have child partitions. Refusing to format whole disk."
  fi

  log "Creating ext4 filesystem on $dev..."
  mkfs.ext4 -F "$dev"
}

mount_volume() {
  local dev="$1"
  mkdir -p "$MOUNT_POINT"

  local uuid
  uuid="$(blkid -s UUID -o value "$dev")"
  [[ -n "$uuid" ]] || die "Could not read UUID from $dev"

  if ! grep -q "$uuid" /etc/fstab; then
    log "Adding UUID mount to /etc/fstab..."
    echo "UUID=$uuid $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
  fi

  mount "$MOUNT_POINT" || true

  if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MOUNT_POINT"
  fi

  log "Mounted $dev at $MOUNT_POINT"
}

get_pg_version() {
  local version
  version="$(pg_lsclusters --no-header | awk 'NR==1 {print $1}')"
  [[ -n "$version" ]] || die "Could not detect PostgreSQL cluster version."
  echo "$version"
}

get_pg_cluster_name() {
  local cluster
  cluster="$(pg_lsclusters --no-header | awk 'NR==1 {print $2}')"
  [[ -n "$cluster" ]] || die "Could not detect PostgreSQL cluster name."
  echo "$cluster"
}

move_postgres_data_to_volume() {
  local pg_version="$1"
  local pg_cluster="$2"

  local old_data="/var/lib/postgresql/${pg_version}/${pg_cluster}"
  local new_root="${MOUNT_POINT}/postgresql"
  local new_data="${new_root}/${pg_version}/${pg_cluster}"

  log "Stopping PostgreSQL..."
  systemctl stop postgresql || true

  mkdir -p "$new_root"
  chown -R postgres:postgres "$new_root"
  chmod 700 "$new_root"

  if [[ -d "$new_data/base" ]]; then
    log "PostgreSQL data already exists on volume: $new_data"
  else
    log "Copying PostgreSQL data from $old_data to $new_data..."
    mkdir -p "$(dirname "$new_data")"
    rsync -aHAX --numeric-ids "$old_data/" "$new_data/"
    chown -R postgres:postgres "$new_data"
    chmod 700 "$new_data"
  fi

  local conf="/etc/postgresql/${pg_version}/${pg_cluster}/postgresql.conf"
  [[ -f "$conf" ]] || die "PostgreSQL config not found: $conf"

  cp -a "$conf" "${conf}.bak.$(date -u +%Y%m%d%H%M%S)"

  if grep -qE "^[# ]*data_directory[ ]*=" "$conf"; then
    sed -i "s|^[# ]*data_directory[ ]*=.*|data_directory = '${new_data}'|" "$conf"
  else
    echo "data_directory = '${new_data}'" >> "$conf"
  fi

  log "Starting PostgreSQL..."
  systemctl start postgresql
  systemctl enable postgresql

  sleep 2
  systemctl --no-pager status postgresql | head -40 || true

  sudo -u postgres psql -tAc "SHOW data_directory;" | grep -q "$new_data" || {
    sudo -u postgres psql -tAc "SHOW data_directory;" || true
    die "PostgreSQL is not using the volume-backed data directory."
  }

  log "PostgreSQL data directory is now on the attached volume: $new_data"
}

create_sample_db() {
  log "Creating sample database and table..."

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 \
    || sudo -u postgres createdb "${DB_NAME}"

  sudo -u postgres psql -d "$DB_NAME" <<SQL
DROP TABLE IF EXISTS ${TABLE_NAME};

CREATE TABLE ${TABLE_NAME} (
  id SERIAL PRIMARY KEY,
  drink_name TEXT NOT NULL,
  why_openstack_engineers_like_it TEXT NOT NULL,
  preferred_time TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO ${TABLE_NAME}
(drink_name, why_openstack_engineers_like_it, preferred_time)
VALUES
('coffee', 'Reliable fuel for long troubleshooting sessions', 'early morning'),
('espresso', 'Fast boost before incident response or cutover', 'before migration window'),
('green tea', 'Calm focus during architecture review', 'mid morning'),
('black tea', 'Steady energy for documentation and runbooks', 'afternoon'),
('yerba mate', 'Long-lasting focus during batch migration work', 'late morning'),
('sparkling water', 'Clean refreshment during command-line work', 'anytime'),
('coconut water', 'Hydration after long maintenance windows', 'after migration'),
('ginger tea', 'Good for calm recovery after production issues', 'evening'),
('Vietnamese iced coffee', 'Strong and sweet fuel for OpenStack engineers', 'hot afternoon'),
('electrolyte drink', 'Useful during overnight cutovers and war rooms', 'night shift');
SQL
}

write_proof_files() {
  local proof_dir="${MOUNT_POINT}/volume_proof"
  mkdir -p "$proof_dir"

  sudo -u postgres psql -d "$DB_NAME" -c "SELECT * FROM ${TABLE_NAME} ORDER BY id;" | tee "${proof_dir}/db_rows_before_snapshot.txt"

  sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM ${TABLE_NAME};" | tee "${proof_dir}/row_count_before_snapshot.txt"

  sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT string_agg(id || ':' || drink_name || ':' || preferred_time, '|' ORDER BY id) FROM ${TABLE_NAME};" \
    | sha256sum \
    | tee "${proof_dir}/db_checksum_before_snapshot.txt"

  sudo -u postgres psql -tAc "SELECT version();" | tee "${proof_dir}/postgres_version.txt"

  date -u +"%Y-%m-%dT%H:%M:%SZ" | tee "${proof_dir}/created_at_utc.txt"

  findmnt "$MOUNT_POINT" | tee "${proof_dir}/mount_info.txt"

  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID | tee "${proof_dir}/lsblk_before_snapshot.txt"

  chown -R postgres:postgres "$proof_dir" || true
}

print_validation() {
  cat <<EOF

============================================================
PostgreSQL DB volume proof is ready.
============================================================

Database:
  ${DB_NAME}

Table:
  ${TABLE_NAME}

PostgreSQL data is on:
  ${MOUNT_POINT}/postgresql

Proof files:
  ${MOUNT_POINT}/volume_proof/

Validate rows:

  sudo -u postgres psql -d ${DB_NAME} -c "SELECT * FROM ${TABLE_NAME} ORDER BY id;"

Validate row count:

  sudo -u postgres psql -d ${DB_NAME} -tAc "SELECT COUNT(*) FROM ${TABLE_NAME};"

Validate checksum:

  sudo -u postgres psql -d ${DB_NAME} -tAc "SELECT string_agg(id || ':' || drink_name || ':' || preferred_time, '|' ORDER BY id) FROM ${TABLE_NAME};" | sha256sum

Before snapshot, flush filesystem:

  sync

Recommended clean snapshot method:

  sudo systemctl stop postgresql
  sync
  # create OSPC volume snapshot from OpenStack CLI
  sudo systemctl start postgresql

OpenStack snapshot command example:

  openstack volume snapshot create --volume <OSPC_VOLUME_ID_OR_NAME> pg-drinks-proof-snap-001

After migration to FLEX:
  attach the migrated FLEX Cinder volume to a FLEX PostgreSQL VM
  mount it at /mnt/pgdata
  point PostgreSQL data_directory to /mnt/pgdata/postgresql/<version>/<cluster>
  start PostgreSQL
  run the same SELECT and checksum commands.

EOF
}

main() {
  require_root
  install_packages
  show_disks

  local dev
  dev="$(detect_device)"
  log "Selected data volume device: $dev"

  format_if_needed "$dev"
  mount_volume "$dev"

  local pg_version
  local pg_cluster

  pg_version="$(get_pg_version)"
  pg_cluster="$(get_pg_cluster_name)"

  log "Detected PostgreSQL cluster: version=${pg_version}, cluster=${pg_cluster}"

  move_postgres_data_to_volume "$pg_version" "$pg_cluster"
  create_sample_db
  write_proof_files
  print_validation
}

main "$@"
