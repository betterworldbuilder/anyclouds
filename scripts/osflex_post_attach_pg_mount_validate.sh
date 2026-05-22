#!/usr/bin/env bash
set -Eeuo pipefail

DEV_HINT="${DEV_HINT:-}"
MOUNT_POINT="${MOUNT_POINT:-}"
REQUESTED_MOUNT_POINT="$MOUNT_POINT"
DB_NAME="${DB_NAME:-openstack_drinks}"
TABLE_NAME="${TABLE_NAME:-preferred_drinks}"
VALIDATE_PG="${VALIDATE_PG:-false}"
DB_VALIDATOR="${DB_VALIDATOR:-none}"
CUSTOM_VALIDATE_CMD="${CUSTOM_VALIDATE_CMD:-}"
ALLOW_LVM="${ALLOW_LVM:-true}"
ALLOW_LUKS="${ALLOW_LUKS:-true}"
UPDATE_PG_CONF="${UPDATE_PG_CONF:-true}"
START_POSTGRES="${START_POSTGRES:-true}"
STRICT_TABLE="${STRICT_TABLE:-false}"

LOG_PREFIX="[OSFLEX-VOL-POSTATTACH]"

log() { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX}[WARN] $*" >&2; }
die() { echo "${LOG_PREFIX}[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root with sudo."
}

install_helpers_if_possible() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y util-linux lvm2 cryptsetup file postgresql-client-common postgresql-client || true
  fi
}

show_disk_state() {
  log "Block devices:"
  lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,PKNAME || true
  log "blkid:"
  blkid || true
}

root_parent_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / || true)"
  src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  if [[ -n "$pk" ]]; then
    echo "/dev/$pk"
  else
    echo "$src"
  fi
}

is_system_device() {
  local dev="$1"
  local base rootdisk
  base="$(basename "$dev")"
  rootdisk="$(root_parent_disk)"

  [[ "$(readlink -f "$dev")" == "$(readlink -f "$rootdisk" 2>/dev/null || echo "$rootdisk")" ]] && return 0

  case "$base" in
    vda|sda|xvda|nvme0n1) return 0 ;;
  esac

  return 1
}

detect_candidate_device() {
  if [[ -n "$DEV_HINT" ]]; then
    [[ -b "$DEV_HINT" ]] || die "DEV_HINT is not a block device: $DEV_HINT"
    is_system_device "$DEV_HINT" && die "Refusing system/root device: $DEV_HINT"
    echo "$DEV_HINT"
    return 0
  fi

  local candidates=()
  while read -r path type fstype mnt; do
    [[ "$type" == "disk" ]] || continue
    is_system_device "$path" && continue
    [[ "$fstype" == "swap" ]] && continue
    if [[ -z "$mnt" || "$mnt" == "-" ]]; then
      candidates+=("$path")
    fi
  done < <(lsblk -nrpo PATH,TYPE,FSTYPE,MOUNTPOINTS)

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    echo "${candidates[0]}"
    return 0
  fi

  show_disk_state
  die "Could not uniquely detect attached migrated volume. Provide DEV_HINT=/dev/vdX."
}

first_fs_partition() {
  local dev="$1"
  lsblk -nrpo NAME,TYPE,FSTYPE "$dev" | awk '$2=="part" && $3!="" {print $1; exit}'
}

whole_disk_fstype() {
  local dev="$1"
  lsblk -ndo FSTYPE "$dev" | head -1
}

detect_mount_device() {
  local dev="$1"

  partprobe "$dev" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true

  local part fs
  part="$(first_fs_partition "$dev" || true)"
  if [[ -n "$part" ]]; then
    echo "$part"
    return 0
  fi

  fs="$(whole_disk_fstype "$dev" || true)"
  if [[ -n "$fs" ]]; then
    echo "$dev"
    return 0
  fi

  if [[ "$ALLOW_LVM" == "true" ]]; then
    pvscan >/dev/null 2>&1 || true
    vgscan >/dev/null 2>&1 || true
    vgchange -ay >/dev/null 2>&1 || true

    local lv
    lv="$(lsblk -nrpo NAME,TYPE,FSTYPE | awk '$2=="lvm" && $3!="" {print $1; exit}')"
    if [[ -n "$lv" ]]; then
      echo "$lv"
      return 0
    fi
  fi

  if [[ "$ALLOW_LUKS" == "true" ]] && command -v cryptsetup >/dev/null 2>&1; then
    if cryptsetup isLuks "$dev" >/dev/null 2>&1; then
      log "LUKS detected on $dev"
      if [[ ! -e /dev/mapper/osflex_pgdata_crypt ]]; then
        cryptsetup luksOpen "$dev" osflex_pgdata_crypt
      fi

      partprobe /dev/mapper/osflex_pgdata_crypt >/dev/null 2>&1 || true
      local crypt_part crypt_fs
      crypt_part="$(first_fs_partition /dev/mapper/osflex_pgdata_crypt || true)"
      if [[ -n "$crypt_part" ]]; then
        echo "$crypt_part"
        return 0
      fi

      crypt_fs="$(whole_disk_fstype /dev/mapper/osflex_pgdata_crypt || true)"
      if [[ -n "$crypt_fs" ]]; then
        echo "/dev/mapper/osflex_pgdata_crypt"
        return 0
      fi
    fi
  fi

  return 1
}

infer_mount_point() {
  if [[ -n "$MOUNT_POINT" ]]; then
    echo "$MOUNT_POINT"
    return 0
  fi

  local conf data_dir mp fstab_mp
  conf="$(ls /etc/postgresql/*/*/postgresql.conf 2>/dev/null | head -1 || true)"

  if [[ -n "$conf" ]]; then
    data_dir="$(grep -E "^[[:space:]]*data_directory[[:space:]]*=" "$conf" 2>/dev/null | tail -1 | sed -E "s/.*=[[:space:]]*'?([^']*)'?.*/\1/" || true)"
    if [[ -n "$data_dir" ]]; then
      if [[ "$data_dir" == /mnt/* ]]; then
        mp="/$(echo "$data_dir" | awk -F/ '{print $2"/"$3}')"
        echo "$mp"
        return 0
      fi
      if [[ "$data_dir" == /data/* ]]; then
        mp="/$(echo "$data_dir" | awk -F/ '{print $2}')"
        echo "$mp"
        return 0
      fi
    fi
  fi

  fstab_mp="$(awk '$1 !~ /^#/ && $2 ~ /(pgdata|postgres|dbvol|database|data)/ {print $2; exit}' /etc/fstab 2>/dev/null || true)"
  if [[ -n "$fstab_mp" ]]; then
    echo "$fstab_mp"
    return 0
  fi

  if [[ "$VALIDATE_PG" == "true" ]]; then
    echo "/mnt/pgdata"
  else
    echo "/mnt/osflex-volume"
  fi
}

mount_volume() {
  local mount_dev="$1"
  local mp="$2"
  local current_src current_real selected_real fallback_mp

  mkdir -p "$mp"

  if mountpoint -q "$mp"; then
    current_src="$(findmnt -n -o SOURCE --target "$mp" || true)"
    current_real="$(readlink -f "$current_src" 2>/dev/null || echo "$current_src")"
    selected_real="$(readlink -f "$mount_dev" 2>/dev/null || echo "$mount_dev")"

    if [[ "$current_real" == "$selected_real" ]]; then
      log "$mp already mounted from selected device."
      findmnt "$mp"
      MOUNT_POINT="$mp"
      return 0
    fi

    if [[ -n "$REQUESTED_MOUNT_POINT" ]]; then
      die "$mp is already mounted from $current_src, not selected device $mount_dev. Unmount it or choose a different MOUNT_POINT."
    fi

    fallback_mp="${mp%/}-$(basename "$mount_dev")"
    warn "$mp is already mounted from $current_src; using $fallback_mp for selected device $mount_dev."
    mkdir -p "$fallback_mp"
    log "Mounting $mount_dev at $fallback_mp"
    mount "$mount_dev" "$fallback_mp"
    findmnt "$fallback_mp"
    MOUNT_POINT="$fallback_mp"
    return 0
  fi

  log "Mounting $mount_dev at $mp"
  mount "$mount_dev" "$mp"
  findmnt "$mp"
  MOUNT_POINT="$mp"
}

validate_generic_mount() {
  local mount_dev="$1"
  local mp="$2"

  log "Generic mount validation:"
  findmnt --target "$mp" -o SOURCE,TARGET,FSTYPE,OPTIONS
  df -hT "$mp" || true
  log "Mounted filesystem probe:"
  lsblk -no NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$mount_dev" || true
  log "Top-level mounted volume contents:"
  find "$mp" -mindepth 1 -maxdepth 2 -printf "%M %u:%g %s %p\n" 2>/dev/null | head -80 || true
}

find_pg_data_dir() {
  local mp="$1"
  local found
  found="$(find "$mp" -maxdepth 8 -type f -name PG_VERSION 2>/dev/null | sort | head -1 || true)"
  [[ -n "$found" ]] || return 1
  dirname "$found"
}

update_pg_conf() {
  local data_dir="$1"
  [[ "$UPDATE_PG_CONF" == "true" ]] || return 0

  local version cluster conf
  version="$(cat "$data_dir/PG_VERSION")"
  log "Detected PGDATA version: $version"

  cluster="$(pg_lsclusters --no-header 2>/dev/null | awk -v v="$version" '$1==v {print $2; exit}' || true)"
  cluster="${cluster:-main}"

  conf="/etc/postgresql/${version}/${cluster}/postgresql.conf"

  if [[ ! -f "$conf" ]]; then
    warn "Matching PostgreSQL config not found: $conf"
    warn "Install matching PostgreSQL server version or update data_directory manually."
    return 0
  fi

  cp -a "$conf" "${conf}.bak.$(date -u +%Y%m%d%H%M%S)"

  if grep -qE "^[#[:space:]]*data_directory[[:space:]]*=" "$conf"; then
    sed -i "s|^[#[:space:]]*data_directory[[:space:]]*=.*|data_directory = '${data_dir}'|" "$conf"
  else
    echo "data_directory = '${data_dir}'" >> "$conf"
  fi

  chown -R postgres:postgres "$(dirname "$(dirname "$data_dir")")" 2>/dev/null || chown -R postgres:postgres "$data_dir" || true
  chmod 700 "$data_dir" || true

  log "Updated PostgreSQL config: $conf"
}

emit_tsv_row_as_table_row() {
  local row="$1"
  local tab=$'\t'
  local cell out="|"

  row="${row}${tab}"
  while [[ "$row" == *"$tab"* ]]; do
    cell="${row%%"$tab"*}"
    row="${row#*"$tab"}"
    cell="${cell//$'\r'/}"
    cell="${cell//$'\n'/ }"
    cell="${cell//|//}"
    [[ -n "$cell" ]] || cell=" "
    out+=" ${cell} |"
  done

  log "$out"
}

emit_tsv_separator_as_table_row() {
  local header="$1"
  local tab=$'\t'
  local out="|"

  header="${header}${tab}"
  while [[ "$header" == *"$tab"* ]]; do
    header="${header#*"$tab"}"
    out+=" --- |"
  done

  log "$out"
}

emit_tsv_as_log_table() {
  local title="$1"
  local tsv="$2"
  local header line

  log "$title"
  header="$(printf "%s\n" "$tsv" | sed -n '1p')"
  if [[ -z "$header" ]]; then
    warn "$title returned no rows."
    return 0
  fi

  emit_tsv_row_as_table_row "$header"
  emit_tsv_separator_as_table_row "$header"

  printf "%s\n" "$tsv" | sed '1d' | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    emit_tsv_row_as_table_row "$line"
  done
}

postgres_psql_tsv() {
  local db="$1"
  local sql="$2"

  if [[ -n "$db" ]]; then
    sudo -u postgres psql -X -A -F $'\t' -P footer=off -P null=NULL -d "$db" -c "$sql"
  else
    sudo -u postgres psql -X -A -F $'\t' -P footer=off -P null=NULL -c "$sql"
  fi
}

postgres_list_tables_and_samples() {
  [[ "$START_POSTGRES" == "true" ]] || return 0

  log "Starting PostgreSQL"
  systemctl start postgresql || {
    warn "PostgreSQL failed to start."
    journalctl -u postgresql -n 100 --no-pager || true
    ls -1 /var/log/postgresql/postgresql-*.log >/dev/null 2>&1 && tail -100 /var/log/postgresql/postgresql-*.log || true
    return 1
  }

  systemctl status postgresql --no-pager | head -40 || true

  local databases tables table sample
  databases="$(postgres_psql_tsv "" "SELECT datname AS name, pg_catalog.pg_get_userbyid(datdba) AS owner, pg_encoding_to_char(encoding) AS encoding, datcollate AS collate, datctype AS ctype FROM pg_database ORDER BY datname;" || true)"
  emit_tsv_as_log_table "PostgreSQL databases:" "$databases"

  tables="$(postgres_psql_tsv "$DB_NAME" "SELECT schemaname AS schema, tablename AS table_name, tableowner AS owner FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;" || true)"
  emit_tsv_as_log_table "PostgreSQL tables in ${DB_NAME}:" "$tables"

  tables="$(sudo -u postgres psql -X -A -t -d "$DB_NAME" -c "SELECT quote_ident(schemaname)||'.'||quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;" || true)"
  if [[ -z "$tables" ]]; then
    warn "No PostgreSQL user tables found or DB is unavailable: $DB_NAME"
    return 0
  fi

  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    sample="$(postgres_psql_tsv "$DB_NAME" "SELECT * FROM ${table} LIMIT 10;" || true)"
    emit_tsv_as_log_table "PostgreSQL sample: ${DB_NAME}.${table} first 10 rows:" "$sample"
  done <<< "$tables"
}

validate_marker() {
  local engine="$1"
  shift
  local found=""
  for pattern in "$@"; do
    found="$(find "$MOUNT_POINT" -maxdepth 8 \( -type f -o -type d \) -name "$pattern" 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && break
  done
  [[ -n "$found" ]] || die "Mounted volume but no ${engine} data markers found under $MOUNT_POINT."
  log "${engine} marker found: $found"
}

mysql_list_tables_and_samples() {
  local engine="$1"
  validate_marker "$engine" "ibdata1" "mysql" "aria_log_control"
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not installed; marker validation only."
    return 0
  fi
  if ! mysql -NBe "SELECT 1" >/dev/null 2>&1; then
    warn "mysql client cannot connect locally; marker validation only."
    return 0
  fi

  local db table
  mysql -NBe "SHOW DATABASES;" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' | while read -r db; do
    [[ -n "$db" ]] || continue
    log "${engine} database: $db"
    mysql -NBe "SHOW TABLES FROM \`$db\`;" | while read -r table; do
      [[ -n "$table" ]] || continue
      log "${engine} sample: ${db}.${table} first 10 rows"
      mysql -e "SELECT * FROM \`$db\`.\`$table\` LIMIT 10;" || true
    done
  done
}

mongodb_list_collections_and_samples() {
  validate_marker "MongoDB" "WiredTiger" "collection-*.wt" "index-*.wt"
  local shell
  shell="$(command -v mongosh || command -v mongo || true)"
  if [[ -z "$shell" ]]; then
    warn "mongo/mongosh client not installed; marker validation only."
    return 0
  fi

  "$shell" --quiet --eval '
const dbs = db.adminCommand({listDatabases:1}).databases || [];
for (const d of dbs) {
  if (["admin","config","local"].includes(d.name)) continue;
  const x = db.getSiblingDB(d.name);
  print("MongoDB database: " + d.name);
  for (const c of x.getCollectionNames()) {
    print("MongoDB sample: " + d.name + "." + c + " first 10 documents");
    x.getCollection(c).find({}).limit(10).forEach(doc => printjson(doc));
  }
}
' || warn "MongoDB client cannot connect locally; marker validation only."
}

redis_list_keys_and_samples() {
  validate_marker "Redis" "dump.rdb" "appendonly.aof" "appendonlydir"
  if ! command -v redis-cli >/dev/null 2>&1; then
    warn "redis-cli not installed; marker validation only."
    return 0
  fi
  if ! redis-cli PING >/dev/null 2>&1; then
    warn "redis-cli cannot connect locally; marker validation only."
    return 0
  fi

  log "Redis first 10 keys and values/type samples"
  redis-cli --scan | head -10 | while read -r key; do
    [[ -n "$key" ]] || continue
    local type
    type="$(redis-cli TYPE "$key" | tr -d '\r')"
    log "Redis key: $key type=$type"
    case "$type" in
      string) redis-cli GET "$key" || true ;;
      hash) redis-cli HGETALL "$key" | head -20 || true ;;
      list) redis-cli LRANGE "$key" 0 9 || true ;;
      set) redis-cli SMEMBERS "$key" | head -10 || true ;;
      zset) redis-cli ZRANGE "$key" 0 9 WITHSCORES || true ;;
    esac
  done
}

run_engine_validator() {
  local data_dir
  [[ "$VALIDATE_PG" == "true" && "$DB_VALIDATOR" == "none" ]] && DB_VALIDATOR="postgresql"

  case "$DB_VALIDATOR" in
    none|"")
      log "No DB engine validator requested."
      return 0
      ;;
    postgresql)
      if ! data_dir="$(find_pg_data_dir "$MOUNT_POINT")"; then
        find "$MOUNT_POINT" -maxdepth 5 -type d | head -80 || true
        die "Mounted volume but no PostgreSQL PG_VERSION found under $MOUNT_POINT."
      fi
      log "Detected PostgreSQL data directory: $data_dir"
      update_pg_conf "$data_dir"
      postgres_list_tables_and_samples
      ;;
    mysql)
      mysql_list_tables_and_samples "MySQL"
      ;;
    mariadb)
      mysql_list_tables_and_samples "MariaDB"
      ;;
    mongodb)
      mongodb_list_collections_and_samples
      ;;
    redis)
      redis_list_keys_and_samples
      ;;
    *)
      die "Unknown DB_VALIDATOR: $DB_VALIDATOR"
      ;;
  esac
}

main() {
  require_root
  install_helpers_if_possible
  show_disk_state

  local dev mount_dev mp data_dir

  dev="$(detect_candidate_device)"
  log "Detected target volume device: $dev"

  if ! mount_dev="$(detect_mount_device "$dev")"; then
    file -s "$dev" || true
    wipefs -n "$dev" || true
    die "Attached volume is not mountable. Do not format. Verify correct OSPC source device/snapshot was migrated."
  fi

  log "Mountable device: $mount_dev"

  mp="$(infer_mount_point)"
  log "Mount point: $mp"

  if [[ "$VALIDATE_PG" == "true" ]]; then
    log "Stopping PostgreSQL before mount"
    systemctl stop postgresql || true
  fi

  mount_volume "$mount_dev" "$mp"
  mp="$MOUNT_POINT"
  validate_generic_mount "$mount_dev" "$mp"

  if [[ "$VALIDATE_PG" != "true" && "$DB_VALIDATOR" == "none" ]]; then
    log "Generic post-attach volume mount validation complete."
    return 0
  fi

  run_engine_validator

  log "Post-attach validation complete."
}

main "$@"
