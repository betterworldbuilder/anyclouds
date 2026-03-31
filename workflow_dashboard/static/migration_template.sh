# ---------- Helpers ----------
PASS_COUNT=0
FAIL_COUNT=0
printf '%s\n' 'step_id,phase,component,source,target,action,status,exit_code,error' > "$RESULTS_CSV"

log() { printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

append_result() {
  local step_id="$1" phase="$2" component="$3" source="$4" target="$5" action="$6" status="$7" exit_code="$8" error="$9"
  error=${error//,/;}
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$step_id" "$phase" "$component" "$source" "$target" "$action" "$status" "$exit_code" "$error" >> "$RESULTS_CSV"
  if [[ "$status" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_cmd() {
  local step_id="$1" phase="$2" component="$3" source="$4" target="$5" action="$6"
  shift 6
  local cmd=("$@")
  log "RUN [$step_id] $action :: ${cmd[*]}"
  if [[ "$DRY_RUN" == "1" ]]; then
    append_result "$step_id" "$phase" "$component" "$source" "$target" "$action" "PASS" "0" "DRY_RUN"
    return 0
  fi
  local rc=0
  local err_file
  err_file=$(mktemp)
  if "${cmd[@]}" 2>"$err_file"; then
    append_result "$step_id" "$phase" "$component" "$source" "$target" "$action" "PASS" "0" ""
    rm -f "$err_file"
    return 0
  fi
  rc=$?
  local err
  err=$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g')
  append_result "$step_id" "$phase" "$component" "$source" "$target" "$action" "FAIL" "$rc" "$err"
  rm -f "$err_file"
  return "$rc"
}

ssh_opts_base=(-o "BatchMode=yes" -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}" -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}")

build_ssh_cmd() {
  local key_path="$1" port="$2" jump_host="$3"
  local -a cmd=(ssh "${ssh_opts_base[@]}" -i "$key_path" -p "$port")
  if [[ -n "$jump_host" ]]; then
    cmd+=(-J "$jump_host")
  fi
  printf '%q ' "${cmd[@]}"
}

build_rsync_ssh() {
  local key_path="$1" port="$2" jump_host="$3"
  local -a parts=(ssh "${ssh_opts_base[@]}" -i "$key_path" -p "$port")
  if [[ -n "$jump_host" ]]; then
    parts+=(-J "$jump_host")
  fi
  printf '%q ' "${parts[@]}"
}

remote_exec() {
  local key_path="$1" user="$2" host="$3" port="$4" jump_host="$5" command="$6"
  local ssh_cmd
  ssh_cmd=$(build_ssh_cmd "$key_path" "$port" "$jump_host")
  bash -lc "$ssh_cmd ${user}@${host} $(printf '%q' "$command")"
}

require_binary() {
  command -v "$1" >/dev/null 2>&1 || fail "Required binary not found: $1"
}

require_file() {
  [[ -f "$1" ]] || fail "Required file not found: $1"
}

check_array_lengths() {
  local src_name="$1" dst_name="$2"
  local src_len="$3" dst_len="$4"
  [[ "$src_len" -eq "$dst_len" ]] || fail "Array length mismatch: $src_name=$src_len, $dst_name=$dst_len"
}

build_tar_excludes() {
  local -n arr_ref=$1
  local result=""
  local item
  for item in "${arr_ref[@]}"; do
    result+=" --exclude=$(printf '%q' "$item")"
  done
  printf '%s' "$result"
}

checksum_remote_dir() {
  local key_path="$1" user="$2" host="$3" port="$4" jump_host="$5" path="$6"
  remote_exec "$key_path" "$user" "$host" "$port" "$jump_host" \
    "if [ -d '$path' ]; then find '$path' -type f -printf '%P\n' | sort | head -200 | xargs -r sha256sum; fi" \
    | sha256sum | awk '{print $1}'
}

pg_table_count_remote() {
  local key_path="$1" user="$2" host="$3" port="$4" jump_host="$5" db_admin="$6" db_pass="$7" db_name="$8"
  local cmd="sudo -u $db_admin env PGPASSWORD='$db_pass' psql -d '$db_name' -Atqc \"select count(*) from information_schema.tables where table_schema='public';\""
  remote_exec "$key_path" "$user" "$host" "$port" "$jump_host" "$cmd"
}

pg_row_estimate_remote() {
  local key_path="$1" user="$2" host="$3" port="$4" jump_host="$5" db_admin="$6" db_pass="$7" db_name="$8"
  local cmd="sudo -u $db_admin env PGPASSWORD='$db_pass' psql -d '$db_name' -Atqc \"select coalesce(sum(n_live_tup)::bigint,0) from pg_stat_user_tables;\""
  remote_exec "$key_path" "$user" "$host" "$port" "$jump_host" "$cmd"
}

service_action_remote() {
  local key_path="$1" user="$2" host="$3" port="$4" jump_host="$5" service_name="$6" action="$7"
  remote_exec "$key_path" "$user" "$host" "$port" "$jump_host" "sudo systemctl $action '$service_name'"
}

# ---------- Validation / prechecks ----------
require_binary ssh
require_binary rsync
require_binary bash

if [[ -n "${OSPC_KEY_FILE:-}" ]] && [[ -f "$OSPC_KEY_FILE" ]]; then
    export OSPC_KEY_PATH="$OSPC_KEY_FILE"
fi
if [[ -n "${FLEX_KEY_FILE:-}" ]] && [[ -f "$FLEX_KEY_FILE" ]]; then
    export FLEX_KEY_PATH="$FLEX_KEY_FILE"
fi

if [[ ! -f "${OSPC_KEY_PATH:-}" ]] && [[ "$OSPC_KEY_PATH" != "OSPC_KEY_FILE" ]]; then
    fail "OSPC Key not found: $OSPC_KEY_PATH"
fi

# We allow checking only components that are populated (if array > 0 length)
if [[ -n "${OSPC_FE_IPS:-}" ]]; then check_array_lengths "OSPC_FE" "FLEX_FE" "${#OSPC_FE_IPS[@]}" "${#FLEX_FE_IPS[@]}"; fi
if [[ -n "${OSPC_BE_IPS:-}" ]]; then check_array_lengths "OSPC_BE" "FLEX_BE" "${#OSPC_BE_IPS[@]}" "${#FLEX_BE_IPS[@]}"; fi
if [[ -n "${OSPC_DB_IPS:-}" ]]; then check_array_lengths "OSPC_DB" "FLEX_DB" "${#OSPC_DB_IPS[@]}" "${#FLEX_DB_IPS[@]}"; fi

log "Starting OSPC -> FLEX production migration"
log "DRY_RUN=$DRY_RUN MAINTENANCE_MODE=$MAINTENANCE_MODE"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.sh}_${RUN_TS}.log"

# Dual tee bindings specifically targeting the frontend log tracker over subshell process allocations
exec > >(tee -a "$LOG_FILE" -a "${PWD}/migration_log.txt") 2>&1

log "Results CSV: $RESULTS_CSV"

# Connectivity prechecks
if [[ -n "${OSPC_FE_IPS:-}" ]]; then
for i in "${!OSPC_FE_IPS[@]}"; do
  o_cred="${OSPC_FE_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_FE_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  run_cmd "PRE001" "precheck" "ssh" "${OSPC_FE_IPS[$i]}" "-" "check source FE SSH" \
    remote_exec "$o_cred" "$o_usr" "${OSPC_FE_IPS[$i]}" "${OSPC_FE_PORTS[$i]}" "$OSPC_JUMP_HOST" "echo ok"
done
fi
if [[ -n "${FLEX_FE_IPS:-}" ]]; then
for i in "${!FLEX_FE_IPS[@]}"; do
  f_cred="${FLEX_FE_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_FE_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
  run_cmd "PRE002" "precheck" "ssh" "-" "${FLEX_FE_IPS[$i]}" "check target FE SSH" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_FE_IPS[$i]}" "${FLEX_FE_PORTS[$i]}" "$FLEX_JUMP_HOST" "echo ok"
done
fi

if [[ -n "${OSPC_BE_IPS:-}" ]]; then
for i in "${!OSPC_BE_IPS[@]}"; do
  o_cred="${OSPC_BE_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_BE_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  run_cmd "PRE003" "precheck" "ssh" "${OSPC_BE_IPS[$i]}" "-" "check source BE SSH" \
    remote_exec "$o_cred" "$o_usr" "${OSPC_BE_IPS[$i]}" "${OSPC_BE_PORTS[$i]}" "$OSPC_JUMP_HOST" "echo ok"
done
fi
if [[ -n "${FLEX_BE_IPS:-}" ]]; then
for i in "${!FLEX_BE_IPS[@]}"; do
  f_cred="${FLEX_BE_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_BE_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
  run_cmd "PRE004" "precheck" "ssh" "-" "${FLEX_BE_IPS[$i]}" "check target BE SSH" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_BE_IPS[$i]}" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST" "echo ok"
done
fi

if [[ -n "${OSPC_DB_IPS:-}" ]]; then
for i in "${!OSPC_DB_IPS[@]}"; do
  o_cred="${OSPC_DB_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_DB_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  run_cmd "PRE005" "precheck" "db" "${OSPC_DB_IPS[$i]}" "-" "check source DB connectivity" \
    remote_exec "$o_cred" "$o_usr" "${OSPC_DB_IPS[$i]}" "${OSPC_DB_PORTS[$i]}" "$OSPC_JUMP_HOST" "sudo -u $OSPC_DB_ADMIN env PGPASSWORD='$OSPC_DB_PASS' psql -d '${OSPC_DB_NAMES[$i]}' -Atqc 'select 1'"
done
fi
if [[ -n "${FLEX_DB_IPS:-}" ]]; then
for i in "${!FLEX_DB_IPS[@]}"; do
  f_cred="${FLEX_DB_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_DB_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
  run_cmd "PRE006" "precheck" "db" "-" "${FLEX_DB_IPS[$i]}" "check target DB connectivity" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_DB_IPS[$i]}" "${FLEX_DB_PORTS[$i]}" "$FLEX_JUMP_HOST" "sudo -u $FLEX_DB_ADMIN env PGPASSWORD='$FLEX_DB_PASS' psql -d '${FLEX_DB_NAMES[$i]}' -Atqc 'select 1'"
done
fi

if [[ "$MAINTENANCE_MODE" == "1" ]]; then
  run_cmd "MAINT001" "maintenance" "app" "source" "source" "enable source app read-only mode" bash -lc "$ENABLE_APP_READONLY_CMD"
fi

if [[ "$STOP_START_SERVICES" == "1" ]]; then
  if [[ -n "${OSPC_BE_IPS:-}" ]]; then
  for i in "${!OSPC_BE_IPS[@]}"; do
  o_cred="${OSPC_BE_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_BE_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
    run_cmd "SRV001" "services" "backend" "${OSPC_BE_IPS[$i]}" "-" "stop source backend service ${OSPC_BE_SERVICES[$i]:-poc-api}" \
      service_action_remote "$o_cred" "$o_usr" "${OSPC_BE_IPS[$i]}" "${OSPC_BE_PORTS[$i]}" "$OSPC_JUMP_HOST" "${OSPC_BE_SERVICES[$i]:-poc-api}" "stop"
  done
  fi
fi

# ---------- Target Dependencies Configuration ----------
if [[ -n "${FLEX_CUSTOM_IPS:-}" ]]; then
for i in "${!FLEX_CUSTOM_IPS[@]}"; do
  f_cred="${FLEX_CUSTOM_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_CUSTOM_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
  C_NAME="${CUSTOM_NODE_NAMES[$i]:-customnode}"
  C_OS="${FLEX_CUSTOM_OS[$i]:-Unknown}"
  C_PKGS="${FLEX_CUSTOM_PACKAGES[$i]:-}"
  C_RUNTIMES="${FLEX_CUSTOM_RUNTIMES[$i]:-}"
  C_ENV="${FLEX_CUSTOM_ENV[$i]:-}"
  
  # Sanitize runtimes and merge with packages
  MAPPED_RUNTIMES="${C_RUNTIMES//node.js/nodejs}"
  MAPPED_RUNTIMES="${MAPPED_RUNTIMES//python/python3}"
  MAPPED_RUNTIMES="${MAPPED_RUNTIMES//java/default-jdk}"
  
  ALL_DEPS="$C_PKGS $MAPPED_RUNTIMES"
  # Trim extra spaces
  ALL_DEPS="$(echo -e "${ALL_DEPS}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  
  if [[ -n "$ALL_DEPS" ]]; then
    step_id="DEP$(printf '%03d' "$((i + 1))")"
    
    # Guardrail: Verify dependencies instead of installing
    check_cmd="for pkg in $ALL_DEPS; do dpkg -l | grep -E '^ii' | grep -q \"\$pkg\" || command -v \"\$pkg\" >/dev/null || { echo \"Missing dependency: \$pkg. Please run Stage 1 Installation first.\"; exit 1; }; done"
    
    run_cmd "${step_id}" "dependency_check" "$C_NAME" "-" "${FLEX_CUSTOM_IPS[$i]}" "verify dependencies on target: $ALL_DEPS" \
      remote_exec "$f_cred" "$f_usr" "${FLEX_CUSTOM_IPS[$i]}" "${FLEX_CUSTOM_PORTS[$i]}" "$FLEX_JUMP_HOST" "$check_cmd"
      
    if [ $? -ne 0 ]; then
       log "Guardrail triggered: Missing OS packages or runtimes on target ${FLEX_CUSTOM_IPS[$i]}. Tracking skip."
       eval "SKIP_CUSTOM_NODE_${i}=1"
       continue
    fi
  fi

  if [[ -n "$C_ENV" && "$C_ENV" != "None" ]]; then
    step_id="ENV$(printf '%03d' "$((i + 1))")"
    
    # Guardrail: Instead of overwriting /etc/environment, check if the env variables are present
    check_env_cmd="echo '$C_ENV' | awk '{gsub(/::::/,\"\\n\"); print}' | while read -r line; do if ! grep -qF \"\$line\" /etc/environment; then echo \"Missing ENV: \$line\"; exit 1; fi; done"
    
    run_cmd "${step_id}" "environment_check" "$C_NAME" "-" "${FLEX_CUSTOM_IPS[$i]}" "verify ENV vars in /etc/environment" \
      remote_exec "$f_cred" "$f_usr" "${FLEX_CUSTOM_IPS[$i]}" "${FLEX_CUSTOM_PORTS[$i]}" "$FLEX_JUMP_HOST" "$check_env_cmd"
      
    if [ $? -ne 0 ]; then
       log "Guardrail triggered: Missing Environment variables on target ${FLEX_CUSTOM_IPS[$i]}. Tracking skip."
       eval "SKIP_CUSTOM_NODE_${i}=1"
       continue
    fi
  fi
done
fi

# ---------- Database migration ----------
if [[ -n "${OSPC_DB_IPS:-}" ]]; then
for i in "${!OSPC_DB_IPS[@]}"; do
  o_cred="${OSPC_DB_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_DB_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  [[ "${OSPC_DB_TYPES[$i]:-postgresql}" == "postgresql" ]] || fail "Unsupported DB type: ${OSPC_DB_TYPES[$i]}"

  src_table_count=$(pg_table_count_remote "$o_cred" "$OSPC_SSH_USER" "${OSPC_DB_IPS[$i]}" "${OSPC_DB_PORTS[$i]}" "$OSPC_JUMP_HOST" "$OSPC_DB_ADMIN" "$OSPC_DB_PASS" "${OSPC_DB_NAMES[$i]}")
  src_row_estimate=$(pg_row_estimate_remote "$o_cred" "$OSPC_SSH_USER" "${OSPC_DB_IPS[$i]}" "${OSPC_DB_PORTS[$i]}" "$OSPC_JUMP_HOST" "$OSPC_DB_ADMIN" "$OSPC_DB_PASS" "${OSPC_DB_NAMES[$i]}")
  log "Source DB ${OSPC_DB_IPS[$i]}:${OSPC_DB_NAMES[$i]} tables=$src_table_count est_rows=$src_row_estimate"

  step_id="DB$(printf '%03d' "$((i + 1))")"
  action="logical dump/restore ${OSPC_DB_IPS[$i]}:${OSPC_DB_NAMES[$i]} -> ${FLEX_DB_IPS[$i]}:${FLEX_DB_NAMES[$i]}"
  log "RUN [$step_id] $action"
  if [[ "$DRY_RUN" == "1" ]]; then
    append_result "$step_id" "database" "postgresql" "${OSPC_DB_IPS[$i]}" "${FLEX_DB_IPS[$i]}" "$action" "PASS" "0" "DRY_RUN"
  else
    src_ssh=$(build_ssh_cmd "$OSPC_KEY_PATH" "${OSPC_DB_PORTS[$i]}" "$OSPC_JUMP_HOST")
    dst_ssh=$(build_ssh_cmd "$FLEX_KEY_PATH" "${FLEX_DB_PORTS[$i]}" "$FLEX_JUMP_HOST")
    set +e
    bash -lc "$src_ssh ${OSPC_SSH_USER}@${OSPC_DB_IPS[$i]} $(printf '%q' "sudo -u $OSPC_DB_ADMIN env PGPASSWORD='$OSPC_DB_PASS' pg_dump --clean --if-exists --no-owner --format=plain '${OSPC_DB_NAMES[$i]}'") | $dst_ssh ${FLEX_SSH_USER}@${FLEX_DB_IPS[$i]} $(printf '%q' "sudo -u $FLEX_DB_ADMIN env PGPASSWORD='$FLEX_DB_PASS' psql -v ON_ERROR_STOP=1 -d '${FLEX_DB_NAMES[$i]}'")"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      append_result "$step_id" "database" "postgresql" "${OSPC_DB_IPS[$i]}" "${FLEX_DB_IPS[$i]}" "$action" "PASS" "0" ""
    else
      append_result "$step_id" "database" "postgresql" "${OSPC_DB_IPS[$i]}" "${FLEX_DB_IPS[$i]}" "$action" "FAIL" "$rc" "pg_dump/psql pipeline failed"
      exit "$rc"
    fi
  fi

  dst_table_count=$(pg_table_count_remote "$FLEX_KEY_PATH" "$FLEX_SSH_USER" "${FLEX_DB_IPS[$i]}" "${FLEX_DB_PORTS[$i]}" "$FLEX_JUMP_HOST" "$FLEX_DB_ADMIN" "$FLEX_DB_PASS" "${FLEX_DB_NAMES[$i]}")
  dst_row_estimate=$(pg_row_estimate_remote "$FLEX_KEY_PATH" "$FLEX_SSH_USER" "${FLEX_DB_IPS[$i]}" "${FLEX_DB_PORTS[$i]}" "$FLEX_JUMP_HOST" "$FLEX_DB_ADMIN" "$FLEX_DB_PASS" "${FLEX_DB_NAMES[$i]}")
  log "Target DB ${FLEX_DB_IPS[$i]}:${FLEX_DB_NAMES[$i]} tables=$dst_table_count est_rows=$dst_row_estimate"

  [[ "$src_table_count" == "$dst_table_count" ]] || fail "Post-migration DB table count mismatch for ${OSPC_DB_NAMES[$i]}: src=$src_table_count dst=$dst_table_count"
  log "DB validation passed for ${OSPC_DB_NAMES[$i]}"
done
fi

FE_TAR_EXCLUDES=(".git" ".cache")
BE_TAR_EXCLUDES=("venv" ".venv" "__pycache__" ".git" ".mypy_cache" ".pytest_cache")

# ---------- Frontend rsync ----------
if [[ -n "${OSPC_FE_IPS:-}" ]]; then
for i in "${!OSPC_FE_IPS[@]}"; do
  o_cred="${OSPC_FE_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_FE_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  SOURCE_PATH="${OSPC_FE_PATHS[$i]}"
  TARGET_PATH="${FLEX_FE_PATHS[$i]}"
  step_id="FE$(printf '%03d' "$((i + 1))")"
  run_cmd "${step_id}A" "frontend" "frontend" "${OSPC_FE_IPS[$i]}:$SOURCE_PATH" "${FLEX_FE_IPS[$i]}:$TARGET_PATH" "prepare target FE path" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_FE_IPS[$i]}" "${FLEX_FE_PORTS[$i]}" "$FLEX_JUMP_HOST" "sudo mkdir -p '$TARGET_PATH' && sudo chown -R '$f_usr:$f_usr' '$TARGET_PATH'"

  src_ssh=$(build_ssh_cmd "$OSPC_KEY_PATH" "${OSPC_FE_PORTS[$i]}" "$OSPC_JUMP_HOST")
  dst_ssh=$(build_ssh_cmd "$FLEX_KEY_PATH" "${FLEX_FE_PORTS[$i]}" "$FLEX_JUMP_HOST")
  fe_excludes=$(build_tar_excludes FE_TAR_EXCLUDES)
  
  action="tar memory stream FE ${OSPC_FE_IPS[$i]}:$SOURCE_PATH -> ${FLEX_FE_IPS[$i]}:$TARGET_PATH"
  log "RUN [$step_id] $action"
  if [[ "$DRY_RUN" == "1" ]]; then
    append_result "$step_id" "frontend" "frontend" "${OSPC_FE_IPS[$i]}:$SOURCE_PATH" "${FLEX_FE_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" "DRY_RUN"
  else
    set +e
    src_cmd="$src_ssh ${OSPC_SSH_USER}@${OSPC_FE_IPS[$i]} \"sudo tar -czf - $fe_excludes -C \\$(dirname \\\"$SOURCE_PATH\\\") \\$(basename \\\"$SOURCE_PATH\\\")\""
    dst_cmd="$dst_ssh ${FLEX_SSH_USER}@${FLEX_FE_IPS[$i]} \"sudo tar -xzf - -C \\$(dirname \\\"$TARGET_PATH\\\")\""
    bash -lc "$src_cmd | $dst_cmd"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      append_result "$step_id" "frontend" "frontend" "${OSPC_FE_IPS[$i]}:$SOURCE_PATH" "${FLEX_FE_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" ""
    else
      append_result "$step_id" "frontend" "frontend" "${OSPC_FE_IPS[$i]}:$SOURCE_PATH" "${FLEX_FE_IPS[$i]}:$TARGET_PATH" "$action" "FAIL" "$rc" "tar pipeline failed"
      exit "$rc"
    fi
  fi

  src_sum=$(checksum_remote_dir "$o_cred" "$OSPC_SSH_USER" "${OSPC_FE_IPS[$i]}" "${OSPC_FE_PORTS[$i]}" "$OSPC_JUMP_HOST" "$SOURCE_PATH")
  dst_sum=$(checksum_remote_dir "$FLEX_KEY_PATH" "$FLEX_SSH_USER" "${FLEX_FE_IPS[$i]}" "${FLEX_FE_PORTS[$i]}" "$FLEX_JUMP_HOST" "$TARGET_PATH")
  [[ "$src_sum" == "$dst_sum" ]] || fail "FE checksum sample mismatch: $SOURCE_PATH -> $TARGET_PATH"
done
fi

# ---------- Backend rsync ----------
if [[ -n "${OSPC_BE_IPS:-}" ]]; then
for i in "${!OSPC_BE_IPS[@]}"; do
  o_cred="${OSPC_BE_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_BE_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  SOURCE_PATH="${OSPC_BE_PATHS[$i]}"
  TARGET_PATH="${FLEX_BE_PATHS[$i]}"
  step_id="BE$(printf '%03d' "$((i + 1))")"
  run_cmd "${step_id}A" "backend" "backend" "${OSPC_BE_IPS[$i]}:$SOURCE_PATH" "${FLEX_BE_IPS[$i]}:$TARGET_PATH" "prepare target BE path" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_BE_IPS[$i]}" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST" "sudo mkdir -p '$TARGET_PATH' && sudo chown -R '$f_usr:$f_usr' '$TARGET_PATH'"

  src_ssh=$(build_ssh_cmd "$OSPC_KEY_PATH" "${OSPC_BE_PORTS[$i]}" "$OSPC_JUMP_HOST")
  dst_ssh=$(build_ssh_cmd "$FLEX_KEY_PATH" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST")
  be_excludes=$(build_tar_excludes BE_TAR_EXCLUDES)
  
  action="tar memory stream BE ${OSPC_BE_IPS[$i]}:$SOURCE_PATH -> ${FLEX_BE_IPS[$i]}:$TARGET_PATH"
  log "RUN [$step_id] $action"
  if [[ "$DRY_RUN" == "1" ]]; then
    append_result "$step_id" "backend" "backend" "${OSPC_BE_IPS[$i]}:$SOURCE_PATH" "${FLEX_BE_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" "DRY_RUN"
  else
    set +e
    src_cmd="$src_ssh ${OSPC_SSH_USER}@${OSPC_BE_IPS[$i]} \"sudo tar -czf - $be_excludes -C \\$(dirname \\\"$SOURCE_PATH\\\") \\$(basename \\\"$SOURCE_PATH\\\")\""
    dst_cmd="$dst_ssh ${FLEX_SSH_USER}@${FLEX_BE_IPS[$i]} \"sudo tar -xzf - -C \\$(dirname \\\"$TARGET_PATH\\\")\""
    bash -lc "$src_cmd | $dst_cmd"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      append_result "$step_id" "backend" "backend" "${OSPC_BE_IPS[$i]}:$SOURCE_PATH" "${FLEX_BE_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" ""
    else
      append_result "$step_id" "backend" "backend" "${OSPC_BE_IPS[$i]}:$SOURCE_PATH" "${FLEX_BE_IPS[$i]}:$TARGET_PATH" "$action" "FAIL" "$rc" "tar pipeline failed"
      exit "$rc"
    fi
  fi

  src_sum=$(checksum_remote_dir "$o_cred" "$OSPC_SSH_USER" "${OSPC_BE_IPS[$i]}" "${OSPC_BE_PORTS[$i]}" "$OSPC_JUMP_HOST" "$SOURCE_PATH")
  dst_sum=$(checksum_remote_dir "$FLEX_KEY_PATH" "$FLEX_SSH_USER" "${FLEX_BE_IPS[$i]}" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST" "$TARGET_PATH")
  [[ "$src_sum" == "$dst_sum" ]] || fail "BE checksum sample mismatch: $SOURCE_PATH -> $TARGET_PATH"
done
fi

# ---------- Custom Components tar ----------
if [[ -n "${OSPC_CUSTOM_IPS:-}" ]]; then
for i in "${!OSPC_CUSTOM_IPS[@]}"; do
  local skip_var="SKIP_CUSTOM_NODE_${i}"
  if [[ "${!skip_var:-0}" == "1" ]]; then
    local c_name="${CUSTOM_NODE_NAMES[$i]:-customnode}"
    log "Skipping data migration for custom node $i (${FLEX_CUSTOM_IPS[$i]}) due to failed prerequisites."
    append_result "CS$(printf '%03d' "$((i + 1))")SKP" "custom" "$c_name" "${OSPC_CUSTOM_IPS[$i]}" "${FLEX_CUSTOM_IPS[$i]}" "Data Migration" "FAIL" "SKIP" "Dependency Guardrail Failed"
    continue
  fi
  o_cred="${OSPC_CUSTOM_CREDS[$i]:-}"
  [[ -z "$o_cred" ]] && o_cred="$OSPC_KEY_PATH"
  if [[ "$o_cred" == *BEGIN* ]]; then
    local tmp_o="/tmp/ospc_key_${i}_$$"
    echo -e "$o_cred" > "$tmp_o" && chmod 600 "$tmp_o"
    o_cred="$tmp_o"
  fi
  o_usr="${OSPC_CUSTOM_USERS[$i]:-}"
  [[ -z "$o_usr" ]] && o_usr="$OSPC_SSH_USER"
  C_NAME="${CUSTOM_NODE_NAMES[$i]:-customnode}"
  SOURCE_PATH="${OSPC_CUSTOM_DATA_PATHS[$i]}"
  TARGET_PATH="${FLEX_CUSTOM_DATA_PATHS[$i]}"
  step_id="CS$(printf '%03d' "$((i + 1))")"
  
  run_cmd "${step_id}A" "custom" "$C_NAME" "${OSPC_CUSTOM_IPS[$i]}:$SOURCE_PATH" "${FLEX_CUSTOM_IPS[$i]}:$TARGET_PATH" "prepare target custom path" \
    remote_exec "$f_cred" "$f_usr" "${FLEX_CUSTOM_IPS[$i]}" "${FLEX_CUSTOM_PORTS[$i]}" "$FLEX_JUMP_HOST" "sudo mkdir -p '$TARGET_PATH' && sudo chown -R '$f_usr:$f_usr' '$TARGET_PATH'"

  src_ssh=$(build_ssh_cmd "$OSPC_KEY_PATH" "${OSPC_CUSTOM_PORTS[$i]}" "$OSPC_JUMP_HOST")
  dst_ssh=$(build_ssh_cmd "$FLEX_KEY_PATH" "${FLEX_CUSTOM_PORTS[$i]}" "$FLEX_JUMP_HOST")
  
  action="tar memory stream $C_NAME ${OSPC_CUSTOM_IPS[$i]}:$SOURCE_PATH -> ${FLEX_CUSTOM_IPS[$i]}:$TARGET_PATH"
  log "RUN [$step_id] $action"
  if [[ "$DRY_RUN" == "1" ]]; then
    append_result "$step_id" "custom" "$C_NAME" "${OSPC_CUSTOM_IPS[$i]}:$SOURCE_PATH" "${FLEX_CUSTOM_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" "DRY_RUN"
  else
    set +e
    src_cmd="$src_ssh ${OSPC_SSH_USER}@${OSPC_CUSTOM_IPS[$i]} \"sudo tar -czf - -C \\$(dirname \\\"$SOURCE_PATH\\\") \\$(basename \\\"$SOURCE_PATH\\\")\""
    dst_cmd="$dst_ssh ${FLEX_SSH_USER}@${FLEX_CUSTOM_IPS[$i]} \"sudo tar -xzf - -C \\$(dirname \\\"$TARGET_PATH\\\")\""
    bash -lc "$src_cmd | $dst_cmd"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      append_result "$step_id" "custom" "$C_NAME" "${OSPC_CUSTOM_IPS[$i]}:$SOURCE_PATH" "${FLEX_CUSTOM_IPS[$i]}:$TARGET_PATH" "$action" "PASS" "0" ""
    else
      append_result "$step_id" "custom" "$C_NAME" "${OSPC_CUSTOM_IPS[$i]}:$SOURCE_PATH" "${FLEX_CUSTOM_IPS[$i]}:$TARGET_PATH" "$action" "FAIL" "$rc" "tar pipeline failed"
      exit "$rc"
    fi
  fi
  
  src_sum=$(checksum_remote_dir "$o_cred" "$OSPC_SSH_USER" "${OSPC_CUSTOM_IPS[$i]}" "${OSPC_CUSTOM_PORTS[$i]}" "$OSPC_JUMP_HOST" "$SOURCE_PATH")
  dst_sum=$(checksum_remote_dir "$FLEX_KEY_PATH" "$FLEX_SSH_USER" "${FLEX_CUSTOM_IPS[$i]}" "${FLEX_CUSTOM_PORTS[$i]}" "$FLEX_JUMP_HOST" "$TARGET_PATH")
  [[ "$src_sum" == "$dst_sum" ]] || fail "Custom checksum sample mismatch: $SOURCE_PATH -> $TARGET_PATH"
done
fi

if [[ "$STOP_START_SERVICES" == "1" ]]; then
  if [[ -n "${FLEX_BE_IPS:-}" ]]; then
  for i in "${!FLEX_BE_IPS[@]}"; do
  f_cred="${FLEX_BE_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_BE_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
    run_cmd "SRV101" "services" "backend" "-" "${FLEX_BE_IPS[$i]}" "start target backend service ${FLEX_BE_SERVICES[$i]:-poc-api}" \
      service_action_remote "$f_cred" "$f_usr" "${FLEX_BE_IPS[$i]}" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST" "${FLEX_BE_SERVICES[$i]:-poc-api}" "start"
    run_cmd "SRV102" "services" "backend" "-" "${FLEX_BE_IPS[$i]}" "check target backend service ${FLEX_BE_SERVICES[$i]:-poc-api}" \
      service_action_remote "$f_cred" "$f_usr" "${FLEX_BE_IPS[$i]}" "${FLEX_BE_PORTS[$i]}" "$FLEX_JUMP_HOST" "${FLEX_BE_SERVICES[$i]:-poc-api}" "is-active"
  done
  fi
  if [[ -n "${FLEX_FE_IPS:-}" ]]; then
  for i in "${!FLEX_FE_IPS[@]}"; do
  f_cred="${FLEX_FE_CREDS[$i]:-}"
  [[ -z "$f_cred" ]] && f_cred="$FLEX_KEY_PATH"
  if [[ "$f_cred" == *BEGIN* ]]; then
    local tmp_f="/tmp/flex_key_${i}_$$"
    echo -e "$f_cred" > "$tmp_f" && chmod 600 "$tmp_f"
    f_cred="$tmp_f"
  fi
  f_usr="${FLEX_FE_USERS[$i]:-}"
  [[ -z "$f_usr" ]] && f_usr="$FLEX_SSH_USER"
    run_cmd "SRV103" "services" "frontend" "-" "${FLEX_FE_IPS[$i]}" "reload target FE service ${FLEX_FE_SERVICES[$i]:-nginx}" \
      service_action_remote "$f_cred" "$f_usr" "${FLEX_FE_IPS[$i]}" "${FLEX_FE_PORTS[$i]}" "$FLEX_JUMP_HOST" "${FLEX_FE_SERVICES[$i]:-nginx}" "reload"
  done
  fi
fi

if [[ "$MAINTENANCE_MODE" == "1" ]]; then
  run_cmd "MAINT002" "maintenance" "app" "source" "source" "disable source app read-only mode" bash -lc "$DISABLE_APP_READONLY_CMD"
fi

log "Migration completed: PASS_COUNT=$PASS_COUNT FAIL_COUNT=$FAIL_COUNT"
log "Artifacts: $LOG_FILE , $RESULTS_CSV"
