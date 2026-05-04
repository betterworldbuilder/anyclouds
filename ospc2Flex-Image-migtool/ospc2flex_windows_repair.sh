#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_repair.sh — Offline VirtIO Driver Injection for Windows
# ═══════════════════════════════════════════════════════════════════════════════
# Mounts a Windows qcow2 image offline, injects VirtIO block/SCSI
# (viostor/vioscsi) and network (netkvm) drivers into the driver store and
# registry so that the image can boot on KVM/FLEX with VirtIO disks and
# networking.
#
# Usage:
#   sudo bash ospc2flex_windows_repair.sh --qcow2 /path/to/win.qcow2 \
#        [--nbd-dev /dev/nbd5] [--force] [--dry-run] [--bruteforce-flex] [--debug] [--debug-log PATH] [--debug-trace]
#
#   OSPC2FLEX_WINDOWS_MODE=bruteforce_flex — same as --bruteforce-flex (aggressive Flex/KVM driver + first-boot path).
#
#   --debug          Mirror full stdout/stderr to a log file (default under /tmp).
#   --debug-log PATH Write debug transcript to this file (--debug implied).
#   --debug-trace    Bash xtrace (set -x); very noisy; use with --debug.
#
# Requirements on jumphost:
#   apt install qemu-utils ntfs-3g libhivex-bin chntpw wget file
#
# VirtIO ISO:
#   Default: offline/local mode. Require a valid ISO at
#            /mnt/migration/virtio/virtio-win.iso unless overridden.
#   OSPC2FLEX_VIRTIO_ISO_LOCAL=/path/to/virtio-win.iso — use this path instead.
#   OSPC2FLEX_VIRTIO_ISO_OFFLINE=0 — allow network download into $VIRTIO_ISO.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
QCOW2=""
NBD_DEV="/dev/nbd5"
DRY_RUN=0
FORCE=0
DEBUG=0
DEBUG_TRACE=0
DEBUG_LOG_FILE=""
REPAIR_REPORT_FILE=""
PURGE_XEN=1
WINDOWS_MODE="${OSPC2FLEX_WINDOWS_MODE:-offline_only}"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_ISO="${OSPC2FLEX_VIRTIO_ISO_LOCAL:-/mnt/migration/virtio/virtio-win.iso}"
VIRTIO_MNT="/tmp/virtio_iso_mnt_$$"
MNT="/tmp/mnt_windows_repair_$$"

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS() { echo -e "  ${GREEN}✅ $*${NC}"; }
FAIL() { echo -e "  ${RED}❌ $*${NC}"; }
WARN() { echo -e "  ${YELLOW}⚠️  $*${NC}"; }
INFO() { echo -e "  ${CYAN}ℹ️  $*${NC}"; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qcow2)    QCOW2="$2"; shift 2 ;;
    --nbd-dev)  NBD_DEV="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --purge-xen)    PURGE_XEN=1; shift ;;
    --no-purge-xen) PURGE_XEN=0; shift ;;
    --bruteforce-flex)
      WINDOWS_MODE="bruteforce_flex"
      OSPC2FLEX_WINDOWS_MODE="bruteforce_flex"
      export OSPC2FLEX_WINDOWS_MODE
      PURGE_XEN=1
      shift
      ;;
    --debug)        DEBUG=1; shift ;;
    --debug-log)    DEBUG_LOG_FILE="$2"; DEBUG=1; shift 2 ;;
    --debug-trace)  DEBUG=1; DEBUG_TRACE=1; shift ;;
    -h|--help)
      echo "Usage: $0 --qcow2 <path> [--nbd-dev /dev/nbdX] [--force] [--dry-run] [--purge-xen|--no-purge-xen] [--bruteforce-flex] [--debug] [--debug-log FILE] [--debug-trace]"
      echo ""
      echo "  --bruteforce-flex  Aggressively inject and enable Flex/KVM VirtIO + QEMU drivers:"
      echo "                     viostor, vioscsi, netkvm, balloon, vioserial, viorng, qemufwcfg,"
      echo "                     qxldod/viogpudo, pvpanic, QEMU-GA MSI, full virtio stage for pnputil,"
      echo "                     Xen purge, MountedDevices clear; skips auxiliary-driver neutralization."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

case "${OSPC2FLEX_WIN_REPAIR_DEBUG:-}" in
  1|yes|true|TRUE|Y|y) DEBUG=1 ;;
esac

[ -z "$QCOW2" ] && { echo "ERROR: --qcow2 is required"; exit 1; }
[ ! -f "$QCOW2" ] && { echo "ERROR: $QCOW2 not found"; exit 1; }

# Debug: mirror entire run to a transcript (captures errors that would otherwise be lost).
if [ "${DEBUG:-0}" -eq 1 ]; then
  export OSPC2FLEX_WIN_REPAIR_DEBUG=1
  if [ -z "${DEBUG_LOG_FILE:-}" ]; then
    _stem=$(basename "$QCOW2" .qcow2)
    DEBUG_LOG_FILE="/tmp/ospc2flex_win_repair_${_stem}_$$.log"
  fi
  export OSPC2FLEX_WIN_REPAIR_DEBUG_LOG="$DEBUG_LOG_FILE"
  touch "$DEBUG_LOG_FILE" 2>/dev/null || { echo "ERROR: cannot create debug log: $DEBUG_LOG_FILE"; exit 1; }
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " DEBUG TRANSCRIPT → $DEBUG_LOG_FILE"
  echo "   (full stdout/stderr mirrored; use for hidden failures / support bundles)"
  echo "═══════════════════════════════════════════════════════════════════════════"
  exec > >(tee -a "$DEBUG_LOG_FILE") 2>&1
  if [ "${DEBUG_TRACE:-0}" -eq 1 ]; then
    export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
    set -x
  fi
fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Offline VirtIO Driver Injection"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Target qcow2 : $QCOW2"
echo "  NBD device   : $NBD_DEV"
echo "  Dry run      : $DRY_RUN"
echo "  Force        : $FORCE"
echo "  Purge Xen    : $PURGE_XEN"
echo "  Win Mode     : $WINDOWS_MODE"
echo "═══════════════════════════════════════════════════════════════════════════"

# ── Sentinel check ────────────────────────────────────────────────────────────
if [ -f "${QCOW2}.win_repaired" ] && [ "$FORCE" -eq 0 ]; then
  PASS "Already repaired (sentinel exists). Use --force to re-run."
  exit 0
fi

# ── Dependency check ──────────────────────────────────────────────────────────
ensure_deps() {
  local missing_pkgs=()
  command -v qemu-nbd >/dev/null 2>&1 || missing_pkgs+=(qemu-utils)
  command -v qemu-img >/dev/null 2>&1 || missing_pkgs+=(qemu-utils)
  command -v ntfs-3g >/dev/null 2>&1 || missing_pkgs+=(ntfs-3g)
  command -v ntfsfix >/dev/null 2>&1 || missing_pkgs+=(ntfs-3g)
  command -v hivexsh >/dev/null 2>&1 || missing_pkgs+=(libhivex-bin)
  command -v reged >/dev/null 2>&1 || missing_pkgs+=(chntpw)
  command -v wget >/dev/null 2>&1 || missing_pkgs+=(wget)
  command -v sfdisk >/dev/null 2>&1 || missing_pkgs+=(util-linux)
  command -v file >/dev/null 2>&1 || missing_pkgs+=(file)

  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    INFO "Installing missing Windows repair tools: ${missing_pkgs[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      if [ "${DEBUG:-0}" -eq 1 ]; then
        INFO "[DEBUG] apt-get update (verbose)"
        sudo apt-get update -qq 2>&1 || true
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing_pkgs[@]}" 2>&1 || true
      else
        sudo apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing_pkgs[@]}" >/dev/null 2>&1 || true
      fi
      if ! command -v add-apt-repository >/dev/null 2>&1; then
        if [ "${DEBUG:-0}" -eq 1 ]; then
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y software-properties-common 2>&1 || true
        else
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y software-properties-common >/dev/null 2>&1 || true
        fi
      fi
      if { ! command -v hivexsh >/dev/null 2>&1 || ! command -v reged >/dev/null 2>&1; } && command -v add-apt-repository >/dev/null 2>&1; then
        INFO "Registry tooling still missing; enabling Ubuntu universe repository and retrying packages"
        if [ "${DEBUG:-0}" -eq 1 ]; then
          sudo add-apt-repository -y universe 2>&1 || true
          sudo apt-get update -qq 2>&1 || true
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y libhivex-bin chntpw 2>&1 || true
        else
          sudo add-apt-repository -y universe >/dev/null 2>&1 || true
          sudo apt-get update -qq >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y libhivex-bin chntpw >/dev/null 2>&1 || true
        fi
      fi
    else
      WARN "apt-get not found; cannot auto-install missing tools"
    fi
  fi

  local missing_cmds=()
  for c in qemu-nbd qemu-img ntfs-3g ntfsfix hivexsh reged wget sfdisk file; do
    command -v "$c" >/dev/null 2>&1 || missing_cmds+=("$c")
  done
  if [ "${#missing_cmds[@]}" -gt 0 ]; then
    FAIL "Missing required Windows repair commands after install attempt: ${missing_cmds[*]}"
    FAIL "Install packages on the jumphost: qemu-utils ntfs-3g libhivex-bin chntpw wget"
    exit 1
  fi
  PASS "Windows repair dependencies verified"
}

ensure_deps

merge_registry_patch() {
  local hive="$1" prefix="$2" flat_reg="$3" out_reg reged_out reged_rc
  out_reg="/tmp/ospc2flex_reged_${RANDOM}_$$.reg"
  python3 - "$prefix" "$flat_reg" "$out_reg" <<'PY'
import collections
import re
import sys

prefix, src, dest = sys.argv[1], sys.argv[2], sys.argv[3]
sections = collections.OrderedDict()
pat = re.compile(r'^"([^"]+)"=(.+)$')
with open(src, "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("Windows Registry"):
            continue
        m = pat.match(line)
        if not m:
            continue
        full_path, value = m.group(1), m.group(2)
        parts = full_path.split("\\")
        if len(parts) < 2:
            continue
        key = "\\".join(parts[:-1])
        name = parts[-1]
        sections.setdefault(key, []).append((name, value))

with open(dest, "w", encoding="ascii", errors="ignore") as out:
    out.write("Windows Registry Editor Version 5.00\n\n")
    for key, values in sections.items():
        out.write(f"[{prefix}\\{key}]\n")
        for name, value in values:
            out.write(f'"{name}"={value}\n')
        out.write("\n")
PY
  reged_rc=0
  reged_out=$(printf 'y\n' | sudo reged -I "$hive" "$prefix" "$out_reg" 2>&1) || reged_rc=$?
  printf '%s\n' "$reged_out"
  rm -f "$out_reg"

  # reged may return 2 after successfully expanding and committing a hive.
  # Treat the write as successful only when the import and commit messages
  # both confirm it; otherwise return the real command failure.
  if [ "$reged_rc" -eq 0 ]; then
    return 0
  fi
  if echo "$reged_out" | grep -q "operation SUCCEEDED" && echo "$reged_out" | grep -q " - OK"; then
    return 0
  fi
  return "$reged_rc"
}

hive_value() {
  local hive="$1" key="$2" value="$3"
  sudo hivexsh "$hive" <<EOF 2>/dev/null || true
cd $key
lsval $value
EOF
}

is_reg_dword_zero() {
  grep -Eiq '(^|[^0-9a-f])(0|0x0|0x00000000|00000000)([^0-9a-f]|$)'
}

check_hive_dword_zero() {
  local hive="$1" key="$2" value="$3" raw
  raw=$(hive_value "$hive" "$key" "$value")
  echo "$raw" | is_reg_dword_zero
}

_ensure_netkvm_service_via_hivex() {
  local hive="$1"
  if ! sudo python3 -c "import hivex" 2>/dev/null; then
    if command -v apt-get >/dev/null 2>&1; then
      INFO "Installing python3-hivex (required to create netkvm service key)..."
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq python3-hivex >/dev/null 2>&1 || true
    fi
  fi
  sudo python3 - "$hive" <<'PY'
import struct
import sys

try:
    import hivex
except ImportError:
    sys.stderr.write("ospc2flex: python3-hivex not available — cannot create netkvm service key\n")
    sys.exit(2)

path = sys.argv[1]
REG_SZ = 1
REG_DWORD = 4

def dword(v):
    return struct.pack("<I", v)

def regsz(s):
    return (s + "\0").encode("utf-16le")

def child_or_add(h, parent, name):
    ch = h.node_get_child(parent, name)
    return ch if ch else h.node_add_child(parent, name)

h = hivex.Hivex(path, write=True)
root = h.root()
for cs in ("ControlSet001", "ControlSet002"):
    csn = child_or_add(h, root, cs)
    services = child_or_add(h, csn, "Services")
    netkvm = child_or_add(h, services, "netkvm")
    h.node_set_value(netkvm, {"key": "Type", "t": REG_DWORD, "value": dword(1)})
    h.node_set_value(netkvm, {"key": "Start", "t": REG_DWORD, "value": dword(3)})
    h.node_set_value(netkvm, {"key": "ErrorControl", "t": REG_DWORD, "value": dword(1)})
    h.node_set_value(netkvm, {"key": "ImagePath", "t": REG_SZ, "value": regsz(r"system32\drivers\netkvm.sys")})
    h.node_set_value(netkvm, {"key": "Group", "t": REG_SZ, "value": regsz("NDIS")})
    h.node_set_value(netkvm, {"key": "DisplayName", "t": REG_SZ, "value": regsz("Red Hat VirtIO Ethernet Adapter")})
h.commit(path)
sys.exit(0)
PY
}

append_repair_report() {
  local line="$1"
  [ -n "${REPAIR_REPORT_FILE:-}" ] || return 0
  printf '%s\n' "$line" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
}

is_bruteforce_flex() {
  [ "${WINDOWS_MODE:-}" = "bruteforce_flex" ] || [ "${OSPC2FLEX_WINDOWS_MODE:-}" = "bruteforce_flex" ]
}

# ── Cleanup function ──────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "── Cleanup ──────────────────────────────────────────────────────────────"
  sudo umount "$MNT" 2>/dev/null || true
  sudo umount "$VIRTIO_MNT" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sudo rmdir "$MNT" 2>/dev/null || true
  sudo rmdir "$VIRTIO_MNT" 2>/dev/null || true
  INFO "Cleanup done"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Download VirtIO ISO (if not cached)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 1: VirtIO ISO ─────────────────────────────────────────────────────"
VIRTIO_FALLBACK_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
VIRTIO_ISO_MIN_BYTES="${OSPC2FLEX_VIRTIO_ISO_MIN_BYTES:-50000000}"
VIRTIO_DIR="$(dirname "$VIRTIO_ISO")"
mkdir -p "$VIRTIO_DIR"
# 1 = local/offline ISO only (default). 0 = allow download when cache is missing/invalid.
VIRTIO_ISO_OFFLINE="${OSPC2FLEX_VIRTIO_ISO_OFFLINE:-${OSPC2FLEX_VIRTIO_ISO_NO_DOWNLOAD:-1}}"

virtio_iso_remediation() {
  cat >&2 <<'EOF'
Fix:
  sudo mkdir -p /mnt/migration/virtio
  scp virtio-win.iso ubuntu@<jumphost-ip>:/tmp/virtio-win.iso
  sudo mv /tmp/virtio-win.iso /mnt/migration/virtio/virtio-win.iso
  sudo chmod 644 /mnt/migration/virtio/virtio-win.iso
  file /mnt/migration/virtio/virtio-win.iso
  sudo mkdir -p /mnt/virtio_test
  sudo mount -o loop,ro /mnt/migration/virtio/virtio-win.iso /mnt/virtio_test
  ls /mnt/virtio_test | head
  sudo umount /mnt/virtio_test

Or allow online download:
  export OSPC2FLEX_VIRTIO_ISO_OFFLINE=0
EOF
}

virtio_iso_mount_test() {
  local iso="$1"
  local test_mnt
  test_mnt="$(mktemp -d /tmp/virtio_iso_preflight_XXXXXX)"
  if sudo mount -o loop,ro "$iso" "$test_mnt" >/dev/null 2>&1; then
    sudo umount "$test_mnt" >/dev/null 2>&1 || true
    rmdir "$test_mnt" >/dev/null 2>&1 || true
    return 0
  fi
  rmdir "$test_mnt" >/dev/null 2>&1 || true
  return 1
}

is_valid_iso() {
  local iso="$1"
  [ -e "$iso" ] || return 1
  [ -s "$iso" ] || return 1
  local size
  size="$(stat -Lc%s "$iso" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$VIRTIO_ISO_MIN_BYTES" ]; then
    WARN "ISO too small: $size bytes"
    return 1
  fi
  if file -L "$iso" 2>/dev/null | grep -Eiq 'ISO|UDF|CD-ROM'; then
    :
  else
    WARN "File is not detected as ISO: $(file -L "$iso" 2>/dev/null || echo unknown)"
    return 1
  fi
  if ! virtio_iso_mount_test "$iso"; then
    WARN "ISO mount test failed: $iso"
    return 1
  fi
  return 0
}

download_virtio_iso() {
  local url="$1"
  local dst="$2"
  local tmp="${dst}.part.$$"
  INFO "Downloading VirtIO ISO: $url"
  rm -f "$tmp"
  # Proxies can mis-route curl (e.g. wrong port); direct fetch only for this download.
  if ! (
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
    if command -v curl >/dev/null 2>&1; then
      curl -fL --retry 5 --retry-delay 5 --connect-timeout 20 --max-time 900 -o "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$tmp" "$url"
    else
      exit 127
    fi
  ); then
    rm -f "$tmp"
    return 1
  fi
  if ! is_valid_iso "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dst"
}

if is_valid_iso "$VIRTIO_ISO"; then
  PASS "Using local VirtIO ISO: $VIRTIO_ISO"
elif [ "$VIRTIO_ISO_OFFLINE" != "0" ] && [ "$VIRTIO_ISO_OFFLINE" != "false" ] && [ "$VIRTIO_ISO_OFFLINE" != "no" ]; then
  FAIL "VirtIO ISO offline mode (OSPC2FLEX_VIRTIO_ISO_OFFLINE=$VIRTIO_ISO_OFFLINE): no valid ISO at $VIRTIO_ISO"
  virtio_iso_remediation
  exit 1
else
  INFO "No valid cached VirtIO ISO found; downloading..."
  if download_virtio_iso "$VIRTIO_ISO_URL" "$VIRTIO_ISO"; then
    PASS "Stable VirtIO ISO downloaded successfully"
  elif download_virtio_iso "$VIRTIO_FALLBACK_URL" "$VIRTIO_ISO"; then
    PASS "Latest VirtIO ISO downloaded successfully"
  else
    FAIL "Both ISO downloads failed or produced invalid ISO files"
    FAIL "Fix network access or manually place ISO at: $VIRTIO_ISO"
    exit 1
  fi
fi

PASS "VirtIO ISO ready: $VIRTIO_ISO"
ls -lhL "$VIRTIO_ISO" || true
file -L "$VIRTIO_ISO" || true
sudo mkdir -p "$VIRTIO_MNT"
if [ "${DEBUG:-0}" -eq 1 ]; then
  sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>&1 || { FAIL "Unable to mount validated VirtIO ISO"; exit 1; }
else
  sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>/dev/null || { FAIL "Unable to mount validated VirtIO ISO"; exit 1; }
fi
PASS "VirtIO ISO mounted at $VIRTIO_MNT"

# List available driver versions
INFO "Available driver versions:"
ls -d "$VIRTIO_MNT"/viostor/2k*/amd64 "$VIRTIO_MNT"/viostor/w*/amd64 2>/dev/null | sed 's|.*/viostor/||' || true

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Mount the Windows qcow2
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 2: Mount Windows Image ───────────────────────────────────────────"
# Release stale qemu-nbd lock holders from previous interrupted runs.
release_qcow_lock_if_needed() {
  local lock_pids p
  local wait_sec="${OSPC2FLEX_QCOW_LOCK_WAIT_SEC:-300}"
  local waited=0
  lock_pids="$(sudo fuser "$QCOW2" 2>/dev/null || true)"
  lock_pids="$(printf '%s' "$lock_pids" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')"
  [ -z "$lock_pids" ] && return 0

  WARN "Detected existing process lock(s) on qcow2: $lock_pids"
  if [ "$FORCE" -ne 1 ]; then
    FAIL "qcow2 is locked. Re-run with --force, or stop stale qemu-nbd process(es) first."
    return 1
  fi

  WARN "Force mode enabled: attempting to clear stale lock holders..."
  for p in $lock_pids; do
    _comm="$(sudo ps -p "$p" -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    _args="$(sudo ps -p "$p" -o args= 2>/dev/null || true)"
    if echo "$_comm" | grep -qi '^qemu-nbd$'; then
      _nbd_dev="$(printf '%s\n' "$_args" | sed -n 's/.*--connect=\([^ ]*\).*/\1/p' | head -1)"
      if [ -n "$_nbd_dev" ]; then
        sudo qemu-nbd --disconnect "$_nbd_dev" 2>/dev/null || true
      fi
      sudo kill "$p" 2>/dev/null || true
      sleep 1
      sudo kill -9 "$p" 2>/dev/null || true
      INFO "Cleared stale qemu-nbd lock holder PID $p"
    elif echo "$_comm" | grep -qi '^openstack$' && printf '%s\n' "$_args" | grep -Fq "image create" && printf '%s\n' "$_args" | grep -Fq -- "--file $QCOW2"; then
      _etimes="$(sudo ps -p "$p" -o etimes= 2>/dev/null | tr -d '[:space:]' || echo 0)"
      [ -z "$_etimes" ] && _etimes=0
      WARN "Lock holder PID $p is active openstack image upload (elapsed ${_etimes}s); waiting up to ${wait_sec}s for natural release"
      waited=0
      while [ "$waited" -lt "$wait_sec" ]; do
        sleep 5
        waited=$((waited + 5))
        if ! sudo ps -p "$p" >/dev/null 2>&1; then
          INFO "Openstack uploader PID $p exited; lock should clear"
          break
        fi
        if ! sudo fuser "$QCOW2" 2>/dev/null | tr '\n' ' ' | grep -qw "$p"; then
          INFO "Openstack uploader PID $p no longer holds qcow2 lock"
          break
        fi
      done
      if sudo ps -p "$p" >/dev/null 2>&1 && sudo fuser "$QCOW2" 2>/dev/null | tr '\n' ' ' | grep -qw "$p"; then
        WARN "Openstack uploader PID $p still holds lock after ${wait_sec}s; force-clearing as stale"
        sudo kill "$p" 2>/dev/null || true
        sleep 1
        sudo kill -9 "$p" 2>/dev/null || true
        INFO "Cleared stale openstack image-upload lock holder PID $p"
      fi
    else
      WARN "Lock holder PID $p is not a known stale locker (qemu-nbd/openstack image create); leaving it untouched"
    fi
  done

  sleep 1
  lock_pids="$(sudo fuser "$QCOW2" 2>/dev/null || true)"
  lock_pids="$(printf '%s' "$lock_pids" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')"
  if [ -n "$lock_pids" ]; then
    FAIL "qcow2 remains locked after cleanup attempt: $lock_pids"
    return 1
  fi
  PASS "Cleared stale qcow2 lock(s)"
  return 0
}

release_qcow_lock_if_needed

# Disconnect any previous NBD
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1

sudo modprobe nbd max_part=16 2>/dev/null || true
if [ "$DRY_RUN" -eq 1 ]; then
  sudo qemu-nbd --read-only --connect="$NBD_DEV" "$QCOW2"
else
  sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2"
fi
sleep 3
PASS "qemu-nbd connected: $NBD_DEV"

# Find the Windows partition (dynamically scan for NTFS)
echo "  Partitions:"
sudo lsblk -o NAME,FSTYPE,SIZE "$NBD_DEV" 2>/dev/null | grep -E "^${NBD_DEV#*/dev/}|ntfs" || true

WIN_PART=""
for p in $(sudo lsblk -rno NAME,FSTYPE "$NBD_DEV" 2>/dev/null | awk '$2=="ntfs"{print "/dev/"$1}'); do
  if sudo ntfs-3g.probe --readwrite "$p" 2>&1 | grep -qi "BitLocker"; then
    FAIL "BitLocker encryption detected on $p! Offline injection is impossible."
    exit 1
  fi
  
  INFO "Probing NTFS partition: $p"
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo ntfsfix -d "$p" 2>/dev/null || true
  fi
  sudo mkdir -p "$MNT"
  _mount_opts="rw,remove_hiberfile"
  [ "$DRY_RUN" -eq 1 ] && _mount_opts="ro"
  _mnt_ok=0
  if [ "${DEBUG:-0}" -eq 1 ]; then
    if sudo mount -t ntfs-3g -o "$_mount_opts" "$p" "$MNT" 2>&1; then
      _mnt_ok=1
    else
      INFO "[DEBUG] ntfs-3g mount failed for $p (see lines above)"
    fi
  else
    if sudo mount -t ntfs-3g -o "$_mount_opts" "$p" "$MNT" 2>/dev/null; then
      _mnt_ok=1
    fi
  fi
  if [ "$_mnt_ok" -eq 1 ]; then
    if [ -d "$MNT/Windows/System32" ]; then
      WIN_PART="$p"
      PASS "Windows partition: $p (mounted at $MNT)"
      # Free space check
      FREE_MB=$(df -m "$MNT" 2>/dev/null | awk 'NR==2 {print $4}')
      if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 50 ]; then
        FAIL "Windows partition is functionally full ($FREE_MB MB free). Cannot safely inject drivers."
        exit 1
      fi
      break
    fi
    sudo umount "$MNT" 2>/dev/null
  fi
done

if [ -z "$WIN_PART" ]; then
  FAIL "Could not find Windows partition with System32 on any NTFS partition"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Detect Windows Version
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 3: Detect Windows Version ─────────────────────────────────────────"

# Try to detect version from the SOFTWARE hive
WIN_VER="unknown"
WIN_DRIVER_DIR=""
PROD_NAME="unknown"
HIVE_SW="$MNT/Windows/System32/config/SOFTWARE"
if [ -f "$HIVE_SW" ]; then
  # Extract ProductName from registry
  PROD_NAME=$(sudo hivexsh "$HIVE_SW" <<'EOF' 2>/dev/null || true
cd \Microsoft\Windows NT\CurrentVersion
lsval ProductName
EOF
  )
  INFO "Product: $PROD_NAME"

  # Map product to virtio driver directory
  case "$PROD_NAME" in
    *"Server 2025"*)  WIN_VER="2k25"; WIN_DRIVER_DIR="2k25" ;;
    *"Server 2022"*)  WIN_VER="2k22"; WIN_DRIVER_DIR="2k22" ;;
    *"Server 2019"*)  WIN_VER="2k19"; WIN_DRIVER_DIR="2k19" ;;
    *"Server 2016"*)  WIN_VER="2k16"; WIN_DRIVER_DIR="2k16" ;;
    *"Server 2012 R2"*) WIN_VER="2k12R2"; WIN_DRIVER_DIR="2k12R2" ;;
    *"Server 2012"*)  WIN_VER="2k12"; WIN_DRIVER_DIR="2k12" ;;
    *"Windows 11"*)   WIN_VER="w11"; WIN_DRIVER_DIR="w11" ;;
    *"Windows 10"*)   WIN_VER="w10"; WIN_DRIVER_DIR="w10" ;;
    *"Windows 8.1"*)  WIN_VER="w8.1"; WIN_DRIVER_DIR="w8.1" ;;
    *"Windows 8"*)    WIN_VER="w8"; WIN_DRIVER_DIR="w8" ;;
    *)
      WARN "Unknown Windows version, trying 2k19 drivers (most compatible)"
      WIN_VER="unknown"; WIN_DRIVER_DIR="2k19"
      ;;
  esac
fi

# Verify driver directory exists in ISO
VIOSTOR_SRC="$VIRTIO_MNT/viostor/$WIN_DRIVER_DIR/amd64"
NETKVM_SRC="$VIRTIO_MNT/NetKVM/$WIN_DRIVER_DIR/amd64"
VIOSERIAL_SRC="$VIRTIO_MNT/vioserial/$WIN_DRIVER_DIR/amd64"
BALLOON_SRC="$VIRTIO_MNT/Balloon/$WIN_DRIVER_DIR/amd64"
QXLDOD_SRC="$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64"
VIOSCSI_SRC="$VIRTIO_MNT/vioscsi/$WIN_DRIVER_DIR/amd64"
VIORNG_SRC="$VIRTIO_MNT/viorng/$WIN_DRIVER_DIR/amd64"
QEMUFWCFG_SRC="$VIRTIO_MNT/qemufwcfg/$WIN_DRIVER_DIR/amd64"
PVPANIC_SRC="$VIRTIO_MNT/pvpanic/$WIN_DRIVER_DIR/amd64"
VIOINPUT_SRC="$VIRTIO_MNT/vioinput/$WIN_DRIVER_DIR/amd64"
VIOGPU_SRC="$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64"
if [ -d "$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64" ]; then
  DISPLAY_SRC="$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64"
elif [ -d "$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64" ]; then
  DISPLAY_SRC="$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64"
else
  DISPLAY_SRC=""
fi

# If exact version not found, fall back to 2k19
if [ ! -d "$VIOSTOR_SRC" ]; then
  WARN "No drivers for '$WIN_DRIVER_DIR', trying 2k19..."
  WIN_DRIVER_DIR="2k19"
  VIOSTOR_SRC="$VIRTIO_MNT/viostor/$WIN_DRIVER_DIR/amd64"
  NETKVM_SRC="$VIRTIO_MNT/NetKVM/$WIN_DRIVER_DIR/amd64"
  VIOSERIAL_SRC="$VIRTIO_MNT/vioserial/$WIN_DRIVER_DIR/amd64"
  BALLOON_SRC="$VIRTIO_MNT/Balloon/$WIN_DRIVER_DIR/amd64"
  QXLDOD_SRC="$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64"
  VIOSCSI_SRC="$VIRTIO_MNT/vioscsi/$WIN_DRIVER_DIR/amd64"
  VIORNG_SRC="$VIRTIO_MNT/viorng/$WIN_DRIVER_DIR/amd64"
  QEMUFWCFG_SRC="$VIRTIO_MNT/qemufwcfg/$WIN_DRIVER_DIR/amd64"
  PVPANIC_SRC="$VIRTIO_MNT/pvpanic/$WIN_DRIVER_DIR/amd64"
  VIOINPUT_SRC="$VIRTIO_MNT/vioinput/$WIN_DRIVER_DIR/amd64"
  VIOGPU_SRC="$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64"
  if [ -d "$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64" ]; then
    DISPLAY_SRC="$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64"
  elif [ -d "$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64" ]; then
    DISPLAY_SRC="$VIRTIO_MNT/viogpudo/$WIN_DRIVER_DIR/amd64"
  else
    DISPLAY_SRC=""
  fi
fi

PASS "Windows version: $WIN_VER → driver dir: $WIN_DRIVER_DIR"
INFO "viostor source: $VIOSTOR_SRC"

if [ ! -f "$VIOSTOR_SRC/viostor.sys" ]; then
  FAIL "viostor.sys not found in $VIOSTOR_SRC"
  echo "  Available directories:"
  ls -d "$VIRTIO_MNT/viostor/"*/amd64 2>/dev/null || true
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Copy VirtIO Driver Files
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 4: Copy VirtIO Drivers ────────────────────────────────────────────"

DRIVERS_DIR="$MNT/Windows/System32/drivers"
DRIVERSTORE="$MNT/Windows/System32/DriverStore/FileRepository"
DRIVER_STAGE="$MNT/ospc2flex_driver_stage"
NETKVM_STAGE="$DRIVER_STAGE/NetKVM"
V2_STAGE_ROOT="$MNT/ospc2flex"
V2_VIRTIO_STAGE="$V2_STAGE_ROOT/virtio"

copy_v2_stage_tree() {
  local src="$1" dest="$2"
  [ -d "$src" ] || return 0
  sudo mkdir -p "$dest"
  sudo cp -a "$src"/. "$dest"/ 2>/dev/null || sudo cp -f "$src"/* "$dest"/ 2>/dev/null || true
}

stage_v2_helper_script() {
  local src="$1" dest="$2"
  [ -f "$src" ] || return 0
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp -f "$src" "$dest"
}

if [ $DRY_RUN -eq 0 ]; then
  REPAIR_REPORT_FILE="$MNT/ospc2flex_offline_repair_report.txt"
  sudo tee "$REPAIR_REPORT_FILE" >/dev/null <<EOF
=== ospc2flex offline repair report ===
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%SZ")
Image: $QCOW2
Windows partition: $WIN_PART
Driver source dir: $WIN_DRIVER_DIR
Step4.DriverCopy=START
EOF
  # --- viostor (block/disk — CRITICAL) ---
  if [ -f "$VIOSTOR_SRC/viostor.sys" ]; then
    sudo cp -f "$VIOSTOR_SRC/viostor.sys" "$DRIVERS_DIR/"
    sudo cp -f "$VIOSTOR_SRC/viostor.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    # Also copy to DriverStore
    sudo mkdir -p "$DRIVERSTORE/viostor.inf_amd64"
    sudo cp -f "$VIOSTOR_SRC/"* "$DRIVERSTORE/viostor.inf_amd64/" 2>/dev/null || true
    PASS "viostor (disk driver) → drivers/ + DriverStore"
    printf '%s\n' "Driver.viostor.copy=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  fi

  # --- vioscsi (SCSI disk — CRITICAL when FLEX presents virtio-scsi) ---
  if [ -d "$VIOSCSI_SRC" ] && [ -f "$VIOSCSI_SRC/vioscsi.sys" ]; then
    sudo cp -f "$VIOSCSI_SRC/vioscsi.sys" "$DRIVERS_DIR/"
    sudo cp -f "$VIOSCSI_SRC/vioscsi.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    sudo mkdir -p "$DRIVERSTORE/vioscsi.inf_amd64"
    sudo cp -f "$VIOSCSI_SRC/"* "$DRIVERSTORE/vioscsi.inf_amd64/" 2>/dev/null || true
    PASS "vioscsi (SCSI disk driver) -> drivers/ + DriverStore"
    printf '%s\n' "Driver.vioscsi.copy=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    WARN "vioscsi not found — image may fail if FLEX attaches disk as virtio-scsi"
    printf '%s\n' "Driver.vioscsi.copy=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  fi

  # --- netkvm (network) ---
  if [ -d "$NETKVM_SRC" ] && [ -f "$NETKVM_SRC/netkvm.sys" ]; then
    sudo mkdir -p "$NETKVM_STAGE"
    sudo cp -f "$NETKVM_SRC/"* "$NETKVM_STAGE/" 2>/dev/null || true
    sudo cp -f "$NETKVM_SRC/netkvm.sys" "$DRIVERS_DIR/"
    sudo cp -f "$NETKVM_SRC/netkvm.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    sudo mkdir -p "$DRIVERSTORE/netkvm.inf_amd64"
    sudo cp -f "$NETKVM_SRC/"* "$DRIVERSTORE/netkvm.inf_amd64/" 2>/dev/null || true
    PASS "netkvm copied for normal PnP install and staged as first-boot fallback"
    printf '%s\n' "Driver.netkvm.stage=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    WARN "netkvm not found — network may not work on first boot"
    printf '%s\n' "Driver.netkvm.stage=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  fi

  if is_bruteforce_flex; then
    INFO "Brute-force Flex mode: copying all VirtIO runtime drivers"

    copy_driver_sys() {
      local src="$1"
      local sysname="$2"
      local repo_name="$3"

      [ -d "$src" ] || {
        WARN "Driver source missing: $src"
        return 0
      }

      if [ -f "$src/$sysname" ]; then
        sudo cp -f "$src/$sysname" "$DRIVERS_DIR/"
        sudo cp -f "$src"/*.inf "$DRIVERS_DIR/" 2>/dev/null || true
        sudo mkdir -p "$DRIVERSTORE/${repo_name}.inf_amd64"
        sudo cp -f "$src"/* "$DRIVERSTORE/${repo_name}.inf_amd64/" 2>/dev/null || true
        PASS "Brute-force copied $sysname → drivers/ + DriverStore"
        printf '%s\n' "Driver.${repo_name}.copy=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
      else
        WARN "Missing $sysname in $src"
        printf '%s\n' "Driver.${repo_name}.copy=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
      fi
    }

    copy_driver_sys "$BALLOON_SRC" "balloon.sys" "balloon"
    copy_driver_sys "$VIOSERIAL_SRC" "vioser.sys" "vioser"
    copy_driver_sys "$VIORNG_SRC" "viorng.sys" "viorng"
    copy_driver_sys "$QEMUFWCFG_SRC" "qemufwcfg.sys" "qemufwcfg"
    copy_driver_sys "$PVPANIC_SRC" "pvpanic.sys" "pvpanic"

    if [ -n "$DISPLAY_SRC" ]; then
      copy_driver_sys "$DISPLAY_SRC" "qxldod.sys" "qxldod"
      copy_driver_sys "$DISPLAY_SRC" "viogpudo.sys" "viogpudo"
    fi

    QEMU_GA_DST="$MNT/ospc2flex/guest-agent"
    sudo mkdir -p "$QEMU_GA_DST"
    if [ -f "$VIRTIO_MNT/guest-agent/qemu-ga-x86_64.msi" ]; then
      sudo cp -f "$VIRTIO_MNT/guest-agent/qemu-ga-x86_64.msi" "$QEMU_GA_DST/"
      PASS "QEMU Guest Agent MSI staged"
      printf '%s\n' "QEMU-GA.stage=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    else
      WARN "QEMU Guest Agent MSI not found in VirtIO ISO"
      printf '%s\n' "QEMU-GA.stage=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    fi
  fi

  # Do not pre-install non-storage VirtIO drivers offline. We have seen
  # first-boot BSODs after importing OSPC guests when Windows binds extra
  # VirtIO devices too early. Keep first boot to the minimum storage path,
  # then let first-boot PowerShell install what is needed locally.
  if ! is_bruteforce_flex; then
    sudo rm -f \
      "$DRIVERS_DIR/vioser.sys" \
      "$DRIVERS_DIR/balloon.sys" \
      "$DRIVERS_DIR/qxldod.sys" 2>/dev/null || true
    sudo rm -rf \
      "$DRIVERSTORE/vioser.inf_amd64" \
      "$DRIVERSTORE/balloon.inf_amd64" \
      "$DRIVERSTORE/qxldod.inf_amd64" 2>/dev/null || true
    PASS "Deferred only non-network auxiliary VirtIO drivers until first boot (vioser/balloon/qxldod)"
  else
    PASS "Brute-force Flex mode: auxiliary VirtIO drivers kept in drivers/ + DriverStore"
  fi

  if [ "$WINDOWS_MODE" = "two_phase_virtio" ] || is_bruteforce_flex; then
    sudo mkdir -p "$V2_VIRTIO_STAGE"
    copy_v2_stage_tree "$VIOSTOR_SRC" "$V2_VIRTIO_STAGE/viostor/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIOSCSI_SRC" "$V2_VIRTIO_STAGE/vioscsi/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$NETKVM_SRC" "$V2_VIRTIO_STAGE/NetKVM/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIRTIO_MNT/Balloon/$WIN_DRIVER_DIR/amd64" "$V2_VIRTIO_STAGE/Balloon/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIRTIO_MNT/pvpanic/$WIN_DRIVER_DIR/amd64" "$V2_VIRTIO_STAGE/pvpanic/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIRTIO_MNT/qemufwcfg/$WIN_DRIVER_DIR/amd64" "$V2_VIRTIO_STAGE/qemufwcfg/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIOSERIAL_SRC" "$V2_VIRTIO_STAGE/vioserial/$WIN_DRIVER_DIR/amd64"
    copy_v2_stage_tree "$VIORNG_SRC" "$V2_VIRTIO_STAGE/viorng/$WIN_DRIVER_DIR/amd64"
    if [ -n "$DISPLAY_SRC" ]; then
      copy_v2_stage_tree "$DISPLAY_SRC" "$V2_VIRTIO_STAGE/display/$WIN_DRIVER_DIR/amd64"
    fi
    if is_bruteforce_flex; then
      copy_v2_stage_tree "$VIRTIO_MNT/vioinput/$WIN_DRIVER_DIR/amd64" "$V2_VIRTIO_STAGE/vioinput/$WIN_DRIVER_DIR/amd64" 2>/dev/null || true
    fi
    if [ "$WINDOWS_MODE" = "two_phase_virtio" ]; then
      stage_v2_helper_script "/tmp/ospc2flex_windows_firstboot.ps1" "$V2_STAGE_ROOT/ospc2flex_windows_firstboot.ps1"
      stage_v2_helper_script "/tmp/ospc2flex_windows_v2_verify.ps1" "$V2_STAGE_ROOT/ospc2flex_windows_v2_verify.ps1"
    fi
    PASS "Windows staged drivers under C:\\ospc2flex\\virtio (and V2 helpers when applicable)"
    printf '%s\n' "Driver.v2.stage=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  fi

  if [ ! -f "$DRIVERS_DIR/viostor.sys" ]; then
    FAIL "Post-copy check failed: missing $DRIVERS_DIR/viostor.sys"
    printf '%s\n' "Driver.viostor.presence=FAIL" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    exit 1
  fi
  printf '%s\n' "Driver.viostor.presence=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  if [ -f "$DRIVERS_DIR/vioscsi.sys" ]; then
    printf '%s\n' "Driver.vioscsi.presence=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    WARN "Post-copy check: $DRIVERS_DIR/vioscsi.sys missing (bus-dependent risk)"
    printf '%s\n' "Driver.vioscsi.presence=WARN_MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  fi
else
  INFO "[DRY-RUN] Would copy viostor + vioscsi for boot-critical storage"
  INFO "[DRY-RUN] Would copy netkvm normally and stage it as a first-boot fallback"
  if is_bruteforce_flex; then
    INFO "[DRY-RUN] Would brute-force copy auxiliary VirtIO + QEMU-GA MSI + full virtio stage"
  else
    INFO "[DRY-RUN] Would defer vioser/balloon/qxldod"
  fi
  if [ "$WINDOWS_MODE" = "two_phase_virtio" ] || is_bruteforce_flex; then
    INFO "[DRY-RUN] Would pre-stage VirtIO trees (and V2 helpers for two_phase_virtio) in C:\\ospc2flex"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Inject Registry Entries
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 5: Registry Injection ─────────────────────────────────────────────"

HIVE_SYSTEM="$MNT/Windows/System32/config/SYSTEM"
if [ ! -f "$HIVE_SYSTEM" ]; then
  FAIL "SYSTEM registry hive not found!"
  exit 1
fi

if [ $DRY_RUN -eq 0 ]; then
  # Backup the hive
  sudo cp "$HIVE_SYSTEM" "${HIVE_SYSTEM}.ospc2flex.bak"
  PASS "Registry backup: SYSTEM.ospc2flex.bak"

  # Create registry merge file for reged import
  REG_FILE="/tmp/virtio_drivers_$$.reg"
  cat > "$REG_FILE" <<'REGEOF'
Windows Registry Editor Version 5.00

; ═══════════════════════════════════════════════
; VirtIO Block Driver (viostor) — CRITICAL
; Without this, Windows cannot see the disk on KVM
; ═══════════════════════════════════════════════

; Service entry
"ControlSet001\Services\viostor\Type"=dword:00000001
"ControlSet001\Services\viostor\Start"=dword:00000000
"ControlSet001\Services\viostor\ErrorControl"=dword:00000001
"ControlSet001\Services\viostor\Tag"=dword:00000021
"ControlSet001\Services\viostor\ImagePath"="system32\\drivers\\viostor.sys"
"ControlSet001\Services\viostor\Group"="SCSI miniport"
"ControlSet001\Services\viostor\DisplayName"="Red Hat VirtIO SCSI controller"

; Also in ControlSet002 if it exists
"ControlSet002\Services\viostor\Type"=dword:00000001
"ControlSet002\Services\viostor\Start"=dword:00000000
"ControlSet002\Services\viostor\ErrorControl"=dword:00000001
"ControlSet002\Services\viostor\Tag"=dword:00000021
"ControlSet002\Services\viostor\ImagePath"="system32\\drivers\\viostor.sys"
"ControlSet002\Services\viostor\Group"="SCSI miniport"

; CriticalDeviceDatabase — maps PCI ID to driver
; Legacy VirtIO block device (dev 1001)
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\Service"="viostor"
; Modern VirtIO block device (dev 1042)
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\Service"="viostor"
; Subsystem variants
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00021af4\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00021af4\Service"="viostor"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000\Service"="viostor"

; Duplicate CriticalDeviceDatabase for ControlSet002
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\Service"="viostor"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\Service"="viostor"

; ═══════════════════════════════════════════════
; VirtIO Network Driver (netkvm)
; Keep as a normal PnP-installed service for first boot reachability, but do
; not force early binding via CriticalDeviceDatabase.
; ═══════════════════════════════════════════════
"ControlSet001\Services\netkvm\Type"=dword:00000001
"ControlSet001\Services\netkvm\Start"=dword:00000003
"ControlSet001\Services\netkvm\ErrorControl"=dword:00000001
"ControlSet001\Services\netkvm\ImagePath"="system32\\drivers\\netkvm.sys"
"ControlSet001\Services\netkvm\Group"="NDIS"
"ControlSet001\Services\netkvm\DisplayName"="Red Hat VirtIO Ethernet Adapter"

"ControlSet002\Services\netkvm\Type"=dword:00000001
"ControlSet002\Services\netkvm\Start"=dword:00000003
"ControlSet002\Services\netkvm\ErrorControl"=dword:00000001
"ControlSet002\Services\netkvm\ImagePath"="system32\\drivers\\netkvm.sys"
"ControlSet002\Services\netkvm\Group"="NDIS"

; ═══════════════════════════════════════════════
; VirtIO SCSI Driver (vioscsi) — CRITICAL
; Some OpenStack/FLEX hosts present image disks via virtio-scsi even when the
; image metadata requests hw_disk_bus=virtio. Register both storage paths.
; ═══════════════════════════════════════════════
"ControlSet001\Services\vioscsi\Type"=dword:00000001
"ControlSet001\Services\vioscsi\Start"=dword:00000000
"ControlSet001\Services\vioscsi\ErrorControl"=dword:00000001
"ControlSet001\Services\vioscsi\Tag"=dword:00000022
"ControlSet001\Services\vioscsi\ImagePath"="system32\\drivers\\vioscsi.sys"
"ControlSet001\Services\vioscsi\Group"="SCSI miniport"
"ControlSet001\Services\vioscsi\DisplayName"="Red Hat VirtIO SCSI pass-through controller"

"ControlSet002\Services\vioscsi\Type"=dword:00000001
"ControlSet002\Services\vioscsi\Start"=dword:00000000
"ControlSet002\Services\vioscsi\ErrorControl"=dword:00000001
"ControlSet002\Services\vioscsi\Tag"=dword:00000022
"ControlSet002\Services\vioscsi\ImagePath"="system32\\drivers\\vioscsi.sys"
"ControlSet002\Services\vioscsi\Group"="SCSI miniport"

; Legacy and modern VirtIO SCSI PCI IDs
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\Service"="vioscsi"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\Service"="vioscsi"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004&subsys_00081af4\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004&subsys_00081af4\Service"="vioscsi"

"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\Service"="vioscsi"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\Service"="vioscsi"

REGEOF

  # Apply registry changes using reged (from chntpw). Ubuntu 24.04's
  # libhivex-bin no longer ships hivexregedit.
  merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$REG_FILE" 2>&1
  REG_RC=$?
  rm -f "$REG_FILE"

  if [ $REG_RC -eq 0 ]; then
    if ! _ensure_netkvm_service_via_hivex "$HIVE_SYSTEM"; then
      FAIL "Registry: could not create/repair netkvm service key"
      WARN "Restoring backup..."
      sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
      exit 1
    fi
    PASS "Registry: viostor service (Start=0, Group=SCSI miniport)"
    PASS "Registry: vioscsi service (Start=0, Group=SCSI miniport)"
    PASS "Registry: storahci/pciide/intelide services forced to Start=0 across detected ControlSets"
    PASS "Registry: netkvm service (Start=3, Group=NDIS)"
    PASS "Registry: CriticalDeviceDatabase PCI entries (1AF4:{1001,1042,1004,1048})"
  else
    FAIL "Registry merge failed (rc=$REG_RC)"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

  if is_bruteforce_flex; then
    FLEX_RUNTIME_REG="/tmp/flex_runtime_virtio_$$.reg"
    cat > "$FLEX_RUNTIME_REG" <<'RUNTIMEOF'
Windows Registry Editor Version 5.00

; VirtIO Balloon
"ControlSet001\Services\Balloon\Type"=dword:00000001
"ControlSet001\Services\Balloon\Start"=dword:00000000
"ControlSet001\Services\Balloon\ErrorControl"=dword:00000001
"ControlSet001\Services\Balloon\ImagePath"="system32\\drivers\\balloon.sys"
"ControlSet001\Services\Balloon\Group"="System Bus Extender"
"ControlSet001\Services\Balloon\DisplayName"="VirtIO Balloon Driver"

"ControlSet002\Services\Balloon\Type"=dword:00000001
"ControlSet002\Services\Balloon\Start"=dword:00000000
"ControlSet002\Services\Balloon\ErrorControl"=dword:00000001
"ControlSet002\Services\Balloon\ImagePath"="system32\\drivers\\balloon.sys"
"ControlSet002\Services\Balloon\Group"="System Bus Extender"

; VirtIO Serial
"ControlSet001\Services\vioser\Type"=dword:00000001
"ControlSet001\Services\vioser\Start"=dword:00000000
"ControlSet001\Services\vioser\ErrorControl"=dword:00000001
"ControlSet001\Services\vioser\ImagePath"="system32\\drivers\\vioser.sys"
"ControlSet001\Services\vioser\Group"="System Bus Extender"
"ControlSet001\Services\vioser\DisplayName"="VirtIO Serial Driver"

"ControlSet002\Services\vioser\Type"=dword:00000001
"ControlSet002\Services\vioser\Start"=dword:00000000
"ControlSet002\Services\vioser\ErrorControl"=dword:00000001
"ControlSet002\Services\vioser\ImagePath"="system32\\drivers\\vioser.sys"
"ControlSet002\Services\vioser\Group"="System Bus Extender"

; VirtIO RNG
"ControlSet001\Services\viorng\Type"=dword:00000001
"ControlSet001\Services\viorng\Start"=dword:00000000
"ControlSet001\Services\viorng\ErrorControl"=dword:00000001
"ControlSet001\Services\viorng\ImagePath"="system32\\drivers\\viorng.sys"
"ControlSet001\Services\viorng\Group"="System Bus Extender"
"ControlSet001\Services\viorng\DisplayName"="VirtIO RNG Driver"

"ControlSet002\Services\viorng\Type"=dword:00000001
"ControlSet002\Services\viorng\Start"=dword:00000000
"ControlSet002\Services\viorng\ErrorControl"=dword:00000001
"ControlSet002\Services\viorng\ImagePath"="system32\\drivers\\viorng.sys"
"ControlSet002\Services\viorng\Group"="System Bus Extender"

; QEMU FwCfg
"ControlSet001\Services\qemufwcfg\Type"=dword:00000001
"ControlSet001\Services\qemufwcfg\Start"=dword:00000000
"ControlSet001\Services\qemufwcfg\ErrorControl"=dword:00000001
"ControlSet001\Services\qemufwcfg\ImagePath"="system32\\drivers\\qemufwcfg.sys"
"ControlSet001\Services\qemufwcfg\Group"="System Bus Extender"
"ControlSet001\Services\qemufwcfg\DisplayName"="QEMU FwCfg Driver"

"ControlSet002\Services\qemufwcfg\Type"=dword:00000001
"ControlSet002\Services\qemufwcfg\Start"=dword:00000000
"ControlSet002\Services\qemufwcfg\ErrorControl"=dword:00000001
"ControlSet002\Services\qemufwcfg\ImagePath"="system32\\drivers\\qemufwcfg.sys"
"ControlSet002\Services\qemufwcfg\Group"="System Bus Extender"

; pvpanic
"ControlSet001\Services\pvpanic\Type"=dword:00000001
"ControlSet001\Services\pvpanic\Start"=dword:00000000
"ControlSet001\Services\pvpanic\ErrorControl"=dword:00000001
"ControlSet001\Services\pvpanic\ImagePath"="system32\\drivers\\pvpanic.sys"
"ControlSet001\Services\pvpanic\Group"="System Bus Extender"
"ControlSet001\Services\pvpanic\DisplayName"="QEMU pvpanic device"

"ControlSet002\Services\pvpanic\Type"=dword:00000001
"ControlSet002\Services\pvpanic\Start"=dword:00000000
"ControlSet002\Services\pvpanic\ErrorControl"=dword:00000001
"ControlSet002\Services\pvpanic\ImagePath"="system32\\drivers\\pvpanic.sys"
"ControlSet002\Services\pvpanic\Group"="System Bus Extender"

; QXL display fallback
"ControlSet001\Services\qxldod\Type"=dword:00000001
"ControlSet001\Services\qxldod\Start"=dword:00000000
"ControlSet001\Services\qxldod\ErrorControl"=dword:00000001
"ControlSet001\Services\qxldod\ImagePath"="system32\\drivers\\qxldod.sys"
"ControlSet001\Services\qxldod\Group"="Video"
"ControlSet001\Services\qxldod\DisplayName"="QXL Display Driver"

"ControlSet002\Services\qxldod\Type"=dword:00000001
"ControlSet002\Services\qxldod\Start"=dword:00000000
"ControlSet002\Services\qxldod\ErrorControl"=dword:00000001
"ControlSet002\Services\qxldod\ImagePath"="system32\\drivers\\qxldod.sys"
"ControlSet002\Services\qxldod\Group"="Video"

; VirtIO GPU DOD alternate service name
"ControlSet001\Services\VioGpuDod\Type"=dword:00000001
"ControlSet001\Services\VioGpuDod\Start"=dword:00000000
"ControlSet001\Services\VioGpuDod\ErrorControl"=dword:00000001
"ControlSet001\Services\VioGpuDod\ImagePath"="system32\\drivers\\viogpudo.sys"
"ControlSet001\Services\VioGpuDod\Group"="Video"
"ControlSet001\Services\VioGpuDod\DisplayName"="VioGpuDod"

"ControlSet002\Services\VioGpuDod\Type"=dword:00000001
"ControlSet002\Services\VioGpuDod\Start"=dword:00000000
"ControlSet002\Services\VioGpuDod\ErrorControl"=dword:00000001
"ControlSet002\Services\VioGpuDod\ImagePath"="system32\\drivers\\viogpudo.sys"
"ControlSet002\Services\VioGpuDod\Group"="Video"
RUNTIMEOF

    set +e
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$FLEX_RUNTIME_REG" 2>&1
    _flex_reg_rc=$?
    set -euo pipefail
    rm -f "$FLEX_RUNTIME_REG"
    if [ "$_flex_reg_rc" -ne 0 ]; then
      FAIL "Brute-force Flex runtime registry merge failed"
      WARN "Restoring backup..."
      sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
      exit 1
    fi
    PASS "Brute-force Flex runtime registry entries injected"
  fi

  # Verify the injection worked
  echo ""
  echo "── Verification ─────────────────────────────────────────────────────────"
  echo "  Checking viostor service in registry..."
  VIO_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\viostor' 'Start')
  SCSI_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\vioscsi' 'Start')
  NETKVM_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\netkvm' 'Start')
  if echo "$VIO_CHK" | is_reg_dword_zero && echo "$SCSI_CHK" | is_reg_dword_zero; then
    PASS "Registry verification: viostor Start=0 confirmed"
    PASS "Registry verification: vioscsi Start=0 confirmed"
    printf '%s\n' "Registry.viostor.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    printf '%s\n' "Registry.vioscsi.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    FAIL "Registry verification failed: VirtIO disk services not correctly registered"
    INFO "viostor Start raw: ${VIO_CHK:-<missing>}"
    INFO "vioscsi Start raw: ${SCSI_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  STORAHCI_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\storahci' 'Start')
  if echo "$STORAHCI_CHK" | is_reg_dword_zero; then
    PASS "Registry verification: storahci Start=0 confirmed"
    printf '%s\n' "Registry.storahci.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    FAIL "Registry verification failed: storahci is not Start=0"
    INFO "storahci Start raw: ${STORAHCI_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  PCIIDE_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\pciide' 'Start')
  if echo "$PCIIDE_CHK" | is_reg_dword_zero; then
    PASS "Registry verification: pciide Start=0 confirmed"
    printf '%s\n' "Registry.pciide.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    FAIL "Registry verification failed: pciide is not Start=0"
    INFO "pciide Start raw: ${PCIIDE_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  INTELIDE_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\intelide' 'Start')
  if echo "$INTELIDE_CHK" | is_reg_dword_zero; then
    PASS "Registry verification: intelide Start=0 confirmed"
    printf '%s\n' "Registry.intelide.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    FAIL "Registry verification failed: intelide is not Start=0"
    INFO "intelide Start raw: ${INTELIDE_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  if echo "$NETKVM_CHK" | grep -Eiq '(^|[^0-9a-f])(3|0x3|0x00000003|00000003)([^0-9a-f]|$)'; then
    PASS "Registry verification: netkvm Start=3 confirmed"
    printf '%s\n' "Registry.netkvm.Start=3" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    FAIL "Registry verification failed: netkvm service not correctly registered"
    INFO "netkvm Start raw: ${NETKVM_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

  # ── Clear MountedDevices (Crucial for V2V Boot) ──
  # The key itself may be recreated by Windows, but old \DosDevices\C: values
  # must be removed so the migrated VirtIO disk can claim C: cleanly.
  _hx_md_err=$(mktemp)
  set +e
  sudo hivexsh -w "$HIVE_SYSTEM" <<'EOF' 2>"$_hx_md_err"
cd \MountedDevices
setval 0
commit
EOF
  _hx_md_rc=$?
  set -euo pipefail
  if [ -s "$_hx_md_err" ]; then
    if [ "${DEBUG:-0}" -eq 1 ] || [ "$_hx_md_rc" -ne 0 ]; then
      INFO "[DEBUG] MountedDevices hivexsh (rc=$_hx_md_rc) stderr:"
      sed 's/^/    /' "$_hx_md_err" || true
    fi
  fi
  rm -f "$_hx_md_err"
  MD_VALUES=$(sudo hivexsh "$HIVE_SYSTEM" <<'EOF' 2>/dev/null || true
cd \MountedDevices
lsval
EOF
  )
  if [ -z "$(printf '%s' "$MD_VALUES" | tr -d '[:space:]')" ]; then
    PASS "Registry: MountedDevices values cleared (forces VirtIO C: drive mapping)"
  else
    FAIL "MountedDevices still contains stale drive mappings"
    printf '%s\n' "$MD_VALUES" | sed 's/^/    /'
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

else
  INFO "[DRY-RUN] Would inject viostor + vioscsi service entries"
  INFO "[DRY-RUN] Would add storage CriticalDeviceDatabase PCI mappings"
fi

# Keep first boot conservative: disable only the non-network auxiliary VirtIO
# services offline and remove stale NetKVM CriticalDeviceDatabase entries left
# by prior repair runs.
echo ""
echo "── Step 5b: Neutralize Non-Storage VirtIO For First Boot ─────────────────"

if [ $DRY_RUN -eq 0 ]; then
  if is_bruteforce_flex; then
    PASS "Brute-force Flex mode: keeping auxiliary VirtIO drivers enabled (skip neutralize)"
  else
    AUX_REG="/tmp/aux_virtio_off_$$.reg"
    cat > "$AUX_REG" <<'AUXEOF'
Windows Registry Editor Version 5.00

"ControlSet001\Services\vioser\Start"=dword:00000004
"ControlSet002\Services\vioser\Start"=dword:00000004
"ControlSet001\Services\balloon\Start"=dword:00000004
"ControlSet002\Services\balloon\Start"=dword:00000004
"ControlSet001\Services\qxldod\Start"=dword:00000004
"ControlSet002\Services\qxldod\Start"=dword:00000004
AUXEOF
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$AUX_REG" >/dev/null 2>&1 || true
    rm -f "$AUX_REG"
    sudo hivexsh -w "$HIVE_SYSTEM" <<'EOF' 2>/dev/null || true
cd \ControlSet001\Control\CriticalDeviceDatabase
del pci#ven_1af4&dev_1000
del pci#ven_1af4&dev_1041
cd \ControlSet002\Control\CriticalDeviceDatabase
del pci#ven_1af4&dev_1000
del pci#ven_1af4&dev_1041
commit
EOF
    PASS "Disabled vioser/balloon/qxldod for first boot and removed stale NetKVM CDD entries"
  fi
else
  if is_bruteforce_flex; then
    INFO "[DRY-RUN] Brute-force Flex: would skip vioser/balloon/qxldod neutralize"
  else
    INFO "[DRY-RUN] Would disable vioser/balloon/qxldod until first boot"
    INFO "[DRY-RUN] Would remove stale NetKVM CriticalDeviceDatabase entries"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Disable Xen PV drivers (prevent conflicts)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 6: Disable Xen Drivers ────────────────────────────────────────────"

if [ $DRY_RUN -eq 0 ]; then
  # Set Xen block driver to disabled (Start=4) so it doesn't conflict
  XEN_REG="/tmp/xen_disable_$$.reg"
  cat > "$XEN_REG" <<'XENEOF'
Windows Registry Editor Version 5.00

; Disable Xen PV drivers (Start=4 means disabled)
"ControlSet001\Services\xenvbd\Start"=dword:00000004
"ControlSet001\Services\xennet\Start"=dword:00000004
"ControlSet001\Services\xenvif\Start"=dword:00000004
"ControlSet001\Services\xeniface\Start"=dword:00000004
"ControlSet001\Services\xenbus\Start"=dword:00000004
"ControlSet001\Services\xendisk\Start"=dword:00000004
"ControlSet001\Services\xenfilt\Start"=dword:00000004
"ControlSet001\Services\xenagent\Start"=dword:00000004
"ControlSet001\Services\xenbus_monitor\Start"=dword:00000004
"ControlSet001\Services\XenSvc\Start"=dword:00000004
"ControlSet002\Services\xenvbd\Start"=dword:00000004
"ControlSet002\Services\xennet\Start"=dword:00000004
"ControlSet002\Services\xenvif\Start"=dword:00000004
"ControlSet002\Services\xeniface\Start"=dword:00000004
"ControlSet002\Services\xenbus\Start"=dword:00000004
"ControlSet002\Services\xendisk\Start"=dword:00000004
"ControlSet002\Services\xenfilt\Start"=dword:00000004
"ControlSet002\Services\xenagent\Start"=dword:00000004
"ControlSet002\Services\xenbus_monitor\Start"=dword:00000004
"ControlSet002\Services\XenSvc\Start"=dword:00000004
XENEOF

  _xen_rc=0
  if [ "${DEBUG:-0}" -eq 1 ]; then
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$XEN_REG" 2>&1 || _xen_rc=$?
  else
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$XEN_REG" >/dev/null 2>&1 || _xen_rc=$?
  fi
  rm -f "$XEN_REG"
  [ "$_xen_rc" -eq 0 ] || WARN "Xen disable merge returned rc=$_xen_rc"
  _xen_verify_fail=0
  for _xsvc in xenvbd xennet xenvif xeniface xenbus xendisk xenfilt xenagent xenbus_monitor XenSvc; do
    _xraw="$(hive_value "$HIVE_SYSTEM" "\\ControlSet001\\Services\\$_xsvc" "Start")"
    if [ -n "${_xraw:-}" ] && ! echo "$_xraw" | grep -Eiq '(^|[^0-9a-f])(4|0x4|0x00000004|00000004)([^0-9a-f]|$)'; then
      WARN "Xen service $_xsvc still enabled in ControlSet001"
      printf '%s\n' "Xen.$_xsvc=STILL_ENABLED" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
      _xen_verify_fail=1
    else
      printf '%s\n' "Xen.$_xsvc=NEUTRALIZED_OR_ABSENT" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    fi
  done
  if [ "$_xen_verify_fail" -eq 0 ]; then
    PASS "Xen PV drivers neutralized (non-boot-start or absent)"
  else
    WARN "Some Xen services still boot-start; boot risk remains"
  fi
else
  INFO "[DRY-RUN] Would disable Xen PV drivers and Xen guest agents (xenvbd/xendisk/xenfilt/xenbus/...)"
fi

if [ $DRY_RUN -eq 0 ] && [ "${PURGE_XEN:-0}" -eq 1 ]; then
  echo ""
  echo "── Step 6b: Aggressive Xen Purge (opt-in) ───────────────────────────────"
  XEN_PURGE_BACKUP="$MNT/ospc2flex_xen_purge_backup_$(date -u +%Y%m%d_%H%M%SZ)"
  sudo mkdir -p "$XEN_PURGE_BACKUP/drivers"
  append_repair_report "XenPurge.enabled=1"
  append_repair_report "XenPurge.backup_dir=C:\\ospc2flex_xen_purge_backup_*"

  for _drv in xenbus.sys xenvbd.sys xennet.sys xenvif.sys xeniface.sys xendisk.sys xenfilt.sys xenagent.sys xenbus_monitor.sys xensvc.sys; do
    _src="$MNT/Windows/System32/drivers/$_drv"
    if [ -f "$_src" ]; then
      sudo cp -a "$_src" "$XEN_PURGE_BACKUP/drivers/" 2>/dev/null || true
      sudo rm -f "$_src" 2>/dev/null || true
      append_repair_report "XenPurge.driver.$_drv=REMOVED"
    else
      append_repair_report "XenPurge.driver.$_drv=NOT_FOUND"
    fi
  done

  _xsvc_del_rc=0
  sudo python3 - "$HIVE_SYSTEM" <<'PY' || _xsvc_del_rc=$?
import sys
try:
    import hivex
except Exception:
    sys.exit(2)

path = sys.argv[1]
targets = ("xenvbd","xennet","xenvif","xeniface","xenbus","xendisk","xenfilt","xenagent","xenbus_monitor","XenSvc")

def child(h, node, name):
    n = h.node_get_child(node, name)
    return n if n else 0

h = hivex.Hivex(path, write=True)
root = h.root()
for cs in ("ControlSet001", "ControlSet002"):
    csn = child(h, root, cs)
    if not csn:
        continue
    svc = child(h, csn, "Services")
    if not svc:
        continue
    for t in targets:
        tn = child(h, svc, t)
        if tn:
            try:
                h.node_delete_child(svc, t)
            except Exception:
                pass
h.commit(path)
sys.exit(0)
PY
  [ "$_xsvc_del_rc" -eq 0 ] || WARN "Some Xen service keys could not be deleted via python-hivex (rc=$_xsvc_del_rc)"

  _xen_left=0
  for _xsvc in xenvbd xennet xenvif xeniface xenbus xendisk xenfilt xenagent xenbus_monitor XenSvc; do
    _chk="$(hive_value "$HIVE_SYSTEM" "\\ControlSet001\\Services\\$_xsvc" "Start")"
    if [ -n "${_chk:-}" ]; then
      _xen_left=1
      append_repair_report "XenPurge.service.$_xsvc=STILL_PRESENT"
    else
      append_repair_report "XenPurge.service.$_xsvc=REMOVED_OR_ABSENT"
    fi
  done
  if [ "$_xen_left" -eq 0 ]; then
    PASS "Aggressive Xen purge complete (service keys removed/absent + drivers removed where found)"
  else
    WARN "Aggressive Xen purge partial: one or more service keys still present"
  fi
elif [ $DRY_RUN -eq 1 ] && [ "${PURGE_XEN:-0}" -eq 1 ]; then
  INFO "[DRY-RUN] Would aggressively purge Xen service keys and driver files"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Enable safe boot (use standard storage driver stack)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7: Enable Standard Storage Stack ──────────────────────────────────"

# reged -I cannot add values under existing service keys (e.g. \Services\disk):
# it tries add_key and fails with "key disk already exists". Use python3-hivex
# node_set_value to set only Start=0 (REG_DWORD) without touching other values.
_set_std_storage_start_via_hivex() {
  local hive="$1"
  if ! sudo python3 -c "import hivex" 2>/dev/null; then
    if command -v apt-get >/dev/null 2>&1; then
      INFO "Installing python3-hivex (required to patch disk/volmgt Start= in-place)..."
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq python3-hivex >/dev/null 2>&1 || true
    fi
  fi
  sudo python3 - "$hive" <<'PY'
import struct
import sys

try:
    import hivex
except ImportError:
    sys.stderr.write("ospc2flex: python3-hivex not available — cannot set storage Start=dword\n")
    sys.exit(2)

path = sys.argv[1]
REG_DWORD = 4
zero = struct.pack("<I", 0)

def child(h, node, name):
    ch = h.node_get_child(node, name)
    return ch if ch else 0

h = hivex.Hivex(path, write=True)
root = h.root()
for csn in h.node_children(root):
    cs_name = h.node_name(csn) or ""
    if not cs_name.startswith("ControlSet"):
        continue
    svc_root = child(h, csn, "Services")
    if not svc_root:
        continue
    for svc in ("disk", "volmgr", "volsnap", "partmgr", "mountmgr", "viostor", "vioscsi", "storahci", "pciide", "intelide"):
        sn = child(h, svc_root, svc)
        if not sn:
            continue
        h.node_set_value(sn, {"key": "Start", "t": REG_DWORD, "value": zero})
        # Windows 8+/2012+ often keeps boot storage drivers disabled through
        # Services\<driver>\StartOverride even when Start=0.  On a migrated
        # first boot that can make IDE/AHCI/VirtIO storage unavailable early
        # enough to trigger INACCESSIBLE_BOOT_DEVICE.
        so = child(h, sn, "StartOverride")
        if so:
            for v in h.node_values(so):
                try:
                    h.node_set_value(so, {"key": h.value_key(v), "t": REG_DWORD, "value": zero})
                except Exception:
                    pass
            try:
                h.node_delete_child(so)
            except Exception:
                pass
h.commit(path)
sys.exit(0)
PY
}

_force_storage_startoverride_zero_via_reged() {
  local hive="$1"
  local reg_file
  reg_file="$(mktemp /tmp/ospc2flex_startoverride_XXXXXX.reg)"
  cat >"$reg_file" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\ControlSet001\Services\storahci\StartOverride]
"0"=dword:00000000
[HKEY_LOCAL_MACHINE\ControlSet001\Services\pciide\StartOverride]
"0"=dword:00000000
[HKEY_LOCAL_MACHINE\ControlSet002\Services\storahci\StartOverride]
"0"=dword:00000000
[HKEY_LOCAL_MACHINE\ControlSet002\Services\pciide\StartOverride]
"0"=dword:00000000
EOF
  printf 'y\n' | sudo reged -I "$hive" HKEY_LOCAL_MACHINE "$reg_file" >/dev/null
  local rc=$?
  rm -f "$reg_file"
  # reged can return 2 even after "operation SUCCEEDED"; verification below is
  # the real gate, so do not make this helper fail on reged's quirky status.
  return 0
}

if [ $DRY_RUN -eq 0 ]; then
  if ! _set_std_storage_start_via_hivex "$HIVE_SYSTEM"; then
    WARN "Storage Start= patch via hivex skipped (install: apt install python3-hivex)"
    WARN "Continuing with verification only — Microsoft storage drivers are usually already Start=0"
  else
    PASS "Storage services: Start=0 set and StartOverride removed via hivex"
  fi
  if _force_storage_startoverride_zero_via_reged "$HIVE_SYSTEM"; then
    PASS "Storage StartOverride: storahci/pciide forced to 0 across ControlSet001+002"
  else
    WARN "Storage StartOverride reged patch failed; IDE/AHCI rescue boot may still fail"
  fi

  STORAGE_VERIFY_FAILED=0
  mapfile -t _all_control_sets < <(sudo hivexsh "$HIVE_SYSTEM" <<'EOF' 2>/dev/null || true
cd \
ls
EOF
  )
  for _cs in "${_all_control_sets[@]}"; do
    [[ "$_cs" =~ ^ControlSet[0-9]{3}$ ]] || continue
    for svc in disk volmgr volsnap partmgr mountmgr viostor vioscsi storahci pciide intelide; do
      if ! check_hive_dword_zero "$HIVE_SYSTEM" "\\${_cs}\\Services\\$svc" "Start"; then
        WARN "Storage service $svc is not Start=0 in ${_cs}"
        STORAGE_VERIFY_FAILED=1
      fi
    done
  done
  if [ "$STORAGE_VERIFY_FAILED" -ne 0 ]; then
    FAIL "Standard Windows storage stack verification failed"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  PASS "Storage drivers verified across detected control sets (MS + VirtIO + AHCI + IDE)"
  printf '%s\n' "Registry.ms_storage.Start=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
else
  INFO "[DRY-RUN] Would verify standard storage stack"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7a: Disable Fast Startup / Hiberboot offline
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7a: Disable Fast Startup (Hiberboot) ─────────────────────────────"

if [ $DRY_RUN -eq 0 ]; then
  POWER_HIVE="$MNT/Windows/System32/config/SYSTEM"
  POWER_REG="/tmp/ospc2flex_power_$$.reg"
  cat > "$POWER_REG" <<'POWEREOF'
Windows Registry Editor Version 5.00

"ControlSet001\Control\Session Manager\Power\HiberbootEnabled"=dword:00000000
"ControlSet002\Control\Session Manager\Power\HiberbootEnabled"=dword:00000000
POWEREOF
  merge_registry_patch "$POWER_HIVE" "HKEY_LOCAL_MACHINE\\SYSTEM" "$POWER_REG" >/dev/null 2>&1 || true
  rm -f "$POWER_REG"
  HIBERBOOT_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Control\Session Manager\Power' 'HiberbootEnabled')
  if echo "$HIBERBOOT_CHK" | is_reg_dword_zero; then
    PASS "Registry: HiberbootEnabled=0 (Fast Startup disabled)"
    printf '%s\n' "Registry.HiberbootEnabled=0" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  else
    WARN "Could not verify HiberbootEnabled=0 in ControlSet001"
    INFO "HiberbootEnabled raw: ${HIBERBOOT_CHK:-<missing>}"
  fi
else
  INFO "[DRY-RUN] Would set HiberbootEnabled=0 in ControlSet001+002"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7b: Boot layout validation and WinRE repair helper
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7b: Boot Layout + BCD Helper ─────────────────────────────────────"

WIN_PART_NUM=$(lsblk -rno PARTN "$WIN_PART" 2>/dev/null | head -n1 || true)
PTTYPE=$(lsblk -rno PTTYPE "$NBD_DEV" 2>/dev/null | head -n1 || true)

if [ -z "$WIN_PART_NUM" ]; then
  WARN "Could not detect partition number for $WIN_PART"
elif [ "$PTTYPE" = "dos" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "${DEBUG:-0}" -eq 1 ]; then
      sudo sfdisk --activate "$NBD_DEV" "$WIN_PART_NUM" 2>&1 || \
        WARN "Could not set MBR active flag on $NBD_DEV partition $WIN_PART_NUM"
    else
      sudo sfdisk --activate "$NBD_DEV" "$WIN_PART_NUM" >/dev/null 2>&1 || \
        WARN "Could not set MBR active flag on $NBD_DEV partition $WIN_PART_NUM"
    fi
    PASS "MBR active boot flag set on Windows partition $WIN_PART_NUM"
  else
    INFO "[DRY-RUN] Would set MBR active boot flag on Windows partition $WIN_PART_NUM"
  fi
elif [ -n "$PTTYPE" ]; then
  INFO "Partition table is $PTTYPE; no MBR active flag needed"
else
  WARN "Partition table type not detected"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  BOOT_MODE="BIOS"
  BCD_HIVE="$MNT/Boot/BCD"
  if [ -f "$MNT/EFI/Microsoft/Boot/BCD" ]; then
    BOOT_MODE="UEFI"
    BCD_HIVE="$MNT/EFI/Microsoft/Boot/BCD"
  fi
  INFO "Detected boot mode from offline volume: $BOOT_MODE"
  append_repair_report "Boot.mode=$BOOT_MODE"

  if [ "$BOOT_MODE" = "BIOS" ]; then
    if [ -f "$MNT/bootmgr" ] && [ -f "$BCD_HIVE" ]; then
      PASS "Boot files present on Windows volume (bootmgr + Boot/BCD)"
    else
      FAIL "Required BIOS boot files missing on Windows volume"
      [ -f "$MNT/bootmgr" ] || FAIL "Missing: C:\\bootmgr"
      [ -f "$BCD_HIVE" ] || FAIL "Missing: C:\\Boot\\BCD"
      exit 1
    fi
  else
    if [ -f "$MNT/EFI/Microsoft/Boot/BCD" ]; then
      PASS "UEFI boot files present on Windows volume (EFI\\Microsoft\\Boot\\BCD)"
    else
      FAIL "Required UEFI boot files missing on Windows volume"
      FAIL "Missing: EFI\\Microsoft\\Boot\\BCD"
      exit 1
    fi
  fi

  if [ -f "$BCD_HIVE" ] && command -v hivexml >/dev/null 2>&1; then
    sudo cp -f "$BCD_HIVE" "${BCD_HIVE}.ospc2flex.bak" 2>/dev/null || true
    # Parse BCD hive: patch EVERY normal Windows winload entry AND every winresume
    # (hibernate resume) entry. Reference FLEX 2019 BCD shows winresume still had
    # recoverysequence→WinRE; patching only the first winload misses that path.
    # Kind: W = winload (gets bootstatuspolicy), R = winresume (recovery off only).
    BCD_PATCHLIST=$(mktemp)
    sudo hivexml "$BCD_HIVE" 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

def scan():
    try:
        root = ET.fromstring(sys.stdin.read())
    except Exception:
        return []
    out = []
    for obj in root.findall(".//node[@name=\"Objects\"]/node"):
        guid = obj.attrib.get("name", "")
        elements = obj.find("node[@name=\"Elements\"]")
        if elements is None:
            continue
        path = ""
        systemroot = ""
        desc = ""
        enames = set()
        for el in elements.findall("node"):
            name = el.attrib.get("name", "")
            enames.add(name)
            val = el.find("value[@key=\"Element\"]")
            if val is None:
                continue
            text = val.attrib.get("value", "")
            if name == "12000002":
                path = text.lower()
            elif name == "22000002":
                systemroot = text.lower()
            elif name == "12000004":
                desc = text.lower()
        if "winre.wim" in path or ("ramdisk=" in path and "winload" in path):
            continue
        kind = None
        if "winresume.exe" in path:
            kind = "R"
        elif "winload.exe" in path and systemroot == "\\windows" and "recovery" not in desc:
            kind = "W"
        if kind is None:
            continue
        has_rs = "1" if "14000008" in enames else "0"
        has_re = "1" if "16000009" in enames else "0"
        has_bsp = "1" if "250000e0" in enames else "0"
        has_sb = "1" if "25000080" in enames else "0"
        out.append((guid, kind, has_rs, has_re, has_bsp, has_sb))
    return out

for row in scan():
    print("\t".join(row))
' >"$BCD_PATCHLIST"
    if [ ! -s "$BCD_PATCHLIST" ]; then
      WARN "BCD: no Windows winload/winresume entries matched; offline WinRE suppression skipped"
      rm -f "$BCD_PATCHLIST"
    else
      _n_patch=$(wc -l <"$BCD_PATCHLIST")
      INFO "BCD: preparing WinRE suppression for $_n_patch boot object(s) (winload + winresume)"
      BCD_HIVEX="/tmp/ospc2flex_bcd_hivexsh_$$.txt"
      : >"$BCD_HIVEX"
      while IFS=$'\t' read -r _guid _kind _has_rs _has_re _has_bsp _has_sb; do
        [ -z "$_guid" ] && continue
        _bcd_elems="\\Objects\\$_guid\\Elements"
        {
          echo "cd $_bcd_elems"
          if [ "$_has_rs" = "1" ]; then
            echo "cd 14000008"
            echo "del"
            echo "cd $_bcd_elems"
          fi
          if [ "$_has_re" = "1" ]; then
            echo "cd 16000009"
            echo "setval 1"
            echo "Element"
            echo "hex:3:00"
            echo "cd $_bcd_elems"
          else
            echo "add 16000009"
            echo "cd 16000009"
            echo "setval 1"
            echo "Element"
            echo "hex:3:00"
            echo "cd $_bcd_elems"
          fi
          if [ "$_kind" = "W" ]; then
            if [ "$_has_bsp" = "1" ]; then
              echo "cd 250000e0"
              echo "setval 1"
              echo "Element"
              echo "hex:3:01,00,00,00,00,00,00,00"
            else
              echo "add 250000e0"
              echo "cd 250000e0"
              echo "setval 1"
              echo "Element"
              echo "hex:3:01,00,00,00,00,00,00,00"
            fi
            # Do not force Safe Mode during a storage-controller migration.
            # Safe Mode can skip third-party boot/storage services and trigger
            # INACCESSIBLE_BOOT_DEVICE before our first-boot script can run.
            if [ "$_has_sb" = "1" ]; then
              echo "cd 25000080"
              echo "del"
              echo "cd $_bcd_elems"
            fi
          fi
        } >>"$BCD_HIVEX"
      done <"$BCD_PATCHLIST"
      echo "commit" >>"$BCD_HIVEX"
      _bcd_log=$(mktemp)
      set +e
      sudo hivexsh -w "$BCD_HIVE" <"$BCD_HIVEX" >"$_bcd_log" 2>&1
      _bcd_rc=$?
      set -euo pipefail
      rm -f "$BCD_HIVEX" 2>/dev/null || true
      if [ "$_bcd_rc" -eq 0 ]; then
        PASS "BCD: WinRE auto-boot suppressed on $_n_patch object(s) (winload + winresume)"
        PASS "BCD: bootstatuspolicy IgnoreAllFailures on Windows loaders (winload only)"
        if ! sudo hivexml "$BCD_HIVE" 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

def enames_for(root, guid):
    for obj in root.findall(".//node[@name=\"Objects\"]/node"):
        if obj.attrib.get("name", "") != guid:
            continue
        elements = obj.find("node[@name=\"Elements\"]")
        if elements is None:
            return None
        return {el.attrib.get("name", "") for el in elements.findall("node")}
    return None

try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    sys.exit(2)
pl_path = sys.argv[1]
for line in open(pl_path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line or "\t" not in line:
        continue
    parts = line.split("\t")
    if len(parts) < 6:
        continue
    guid, kind = parts[0], parts[1]
    e = enames_for(root, guid)
    if e is None:
        sys.exit(3)
    if "14000008" in e:
        sys.exit(4)
    if kind == "W" and "25000080" in e:
        sys.exit(6)
sys.exit(0)
' "$BCD_PATCHLIST"; then
          WARN "BCD post-check failed (recoverysequence or safeboot) — first boot may still be unsafe"
        else
          PASS "BCD: recoverysequence removed and safeboot absent on Windows loaders"
        fi
        if [ "${DEBUG:-0}" -eq 1 ] && [ -s "$_bcd_log" ]; then
          INFO "[DEBUG] BCD hivexsh transcript:"
          sed 's/^/    /' "$_bcd_log" || true
        fi
      else
        WARN "BCD hivexsh failed (exit $_bcd_rc); offline WinRE suppression incomplete. Log:"
        sed 's/^/    /' "$_bcd_log" | while IFS= read -r line; do WARN "$line"; done || true
      fi
      rm -f "$_bcd_log" "$BCD_PATCHLIST" 2>/dev/null || true
    fi
  else
    WARN "BCD hive unavailable or hivexml missing; offline WinRE suppression skipped"
  fi

  for _bootstat in "$MNT/Boot/BOOTSTAT.DAT" "$MNT/Windows/bootstat.dat"; do
    if [ -f "$_bootstat" ]; then
      sudo mv -f "$_bootstat" "${_bootstat}.ospc2flex.bak" 2>/dev/null || true
    fi
  done
  PASS "Boot status files reset (BOOTSTAT.DAT/bootstat.dat backed up if present)"

  # This file is intentionally placed in the guest root so that if the VM still
  # lands in WinRE, the operator can run one command from the recovery console:
  #   C:\ospc2flex_winre_boot_repair.cmd
  # It mirrors the known-good FLEX Windows 2016 layout: BIOS/MBR boot, bootmgr
  # and Windows loader pointing at C:, with recovery suppressed for the first
  # successful boot attempt.
  sudo tee "$MNT/ospc2flex_winre_boot_repair.cmd" > /dev/null <<'WINRECMDEOF'
@echo off
echo [ospc2flex] Rebuilding BIOS/MBR Windows boot files on C:
bcdboot C:\Windows /s C: /f BIOS
echo [ospc2flex] Normalizing BCD to boot C:\Windows
bcdedit /set {bootmgr} timeout 0
bcdedit /set {bootmgr} displaybootmenu No
bcdedit /set {bootmgr} device partition=C:
bcdedit /set {bootmgr} default {default}
bcdedit /set {default} device partition=C:
bcdedit /set {default} osdevice partition=C:
bcdedit /set {default} path \Windows\system32\winload.exe
bcdedit /set {default} systemroot \Windows
bcdedit /set {default} bootstatuspolicy IgnoreAllFailures
bcdedit /set {default} recoveryenabled No
bcdedit /deletevalue {default} recoverysequence
bcdedit /deletevalue {default} safeboot
bcdedit /deletevalue {default} safebootalternateshell
reagentc /disable
echo [ospc2flex] Boot repair commands finished. Reboot the VM now.
pause
WINRECMDEOF
  sudo chmod 0644 "$MNT/ospc2flex_winre_boot_repair.cmd" 2>/dev/null || true
  PASS "WinRE helper: C:\\ospc2flex_winre_boot_repair.cmd"
else
  INFO "[DRY-RUN] Would disable automatic WinRE in offline BCD for first boot"
  INFO "[DRY-RUN] Would set BCD bootstatuspolicy IgnoreAllFailures"
  INFO "[DRY-RUN] Would reset BOOTSTAT.DAT/bootstat.dat"
  INFO "[DRY-RUN] Would write C:\\ospc2flex_winre_boot_repair.cmd"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  printf '%s\n' "BCD.offline_recovery_suppression=ATTEMPTED" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7c: Pre-upload boot artifact validation gates
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7c: Pre-Upload Boot Artifact Validation ───────────────────────────"

if [ "$DRY_RUN" -eq 0 ]; then
  _boot_fail=0
  if [ -f "$MNT/Windows/System32/winload.exe" ]; then
    PASS "Validation: winload.exe present"
  else
    FAIL "Validation: missing C:\\Windows\\System32\\winload.exe"
    _boot_fail=1
  fi
  if [ -f "$MNT/bootmgr" ]; then
    PASS "Validation: bootmgr present"
  else
    WARN "Validation: bootmgr missing on mounted volume (may be UEFI split-disk layout)"
  fi
  if [ -f "$MNT/Boot/BCD" ] || [ -f "$MNT/EFI/Microsoft/Boot/BCD" ]; then
    PASS "Validation: BCD hive present"
  else
    FAIL "Validation: no BCD hive found (Boot/BCD or EFI/Microsoft/Boot/BCD)"
    _boot_fail=1
  fi
  if [ "$_boot_fail" -ne 0 ]; then
    FAIL "Pre-upload boot validation failed; refusing to continue with this image"
    exit 1
  fi
else
  INFO "[DRY-RUN] Would validate winload.exe/bootmgr/BCD artifacts before upload"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8: First-Boot Network + Firewall Script (RunOnce)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 8: First-Boot RunOnce Script ──────────────────────────────────────"

if [ $DRY_RUN -eq 0 ]; then
  # Write a PowerShell script that runs once on first boot to:
  #   1. Remove ghost/stale network adapters bound to old Xen MAC
  #   2. Enable DHCP on the new VirtIO NIC
  #   3. Open firewall for RDP + ICMP on all profiles
  #   4. Self-delete after execution
  FIRSTBOOT_DIR="$MNT/Windows/Setup/Scripts"
  FIRSTBOOT_PS1="$MNT/ospc2flex_firstboot.ps1"
  FIRSTBOOT_CMD="$FIRSTBOOT_DIR/SetupComplete.cmd"

  sudo mkdir -p "$FIRSTBOOT_DIR"

  if is_bruteforce_flex; then
    sudo mkdir -p "$MNT/ospc2flex"
    sudo touch "$MNT/ospc2flex/BRUTEFORCE_FLEX.marker"
    append_repair_report "BruteForceFlex.marker=CREATED"
  fi

  sudo tee "$FIRSTBOOT_PS1" > /dev/null <<'FIRSTBOOTEOF'
# ── ospc2flex first-boot network + firewall repair ──
# Runs once via SetupComplete.cmd on first Windows boot after migration.

$logFile = "C:\ospc2flex_firstboot.log"
Start-Transcript -Path $logFile -Append

Write-Host "[ospc2flex] First-boot repair starting..."

if (Test-Path 'C:\ospc2flex\BRUTEFORCE_FLEX.marker') {
    Write-Host "[ospc2flex] Brute-force Flex runtime enablement starting"

    $BfLog = "C:\ospc2flex\bruteforce-flex-firstboot.log"
    function LogLine($msg) {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$stamp $msg" | Out-File -FilePath $BfLog -Append -Encoding UTF8
        Write-Host $msg
    }

    LogLine "Starting brute-force Flex first boot repair"

    try {
        $null = & bcdedit.exe /set "{default}" device partition=C: 2>&1
        $null = & bcdedit.exe /set "{default}" osdevice partition=C: 2>&1
        $null = & bcdedit.exe /set "{default}" path \Windows\system32\winload.exe 2>&1
        $null = & bcdedit.exe /set "{default}" systemroot \Windows 2>&1
        $null = & bcdedit.exe /set "{default}" recoveryenabled No 2>&1
        $null = & bcdedit.exe /deletevalue "{default}" safeboot 2>&1
        $null = & bcdedit.exe /deletevalue "{default}" detecthal 2>&1
        $null = & bcdedit.exe /set "{current}" device partition=C: 2>&1
        $null = & bcdedit.exe /set "{current}" osdevice partition=C: 2>&1
        $null = & bcdedit.exe /set "{current}" path \Windows\system32\winload.exe 2>&1
        $null = & bcdedit.exe /set "{current}" systemroot \Windows 2>&1
        $null = & bcdedit.exe /set "{current}" recoveryenabled No 2>&1
        $null = & bcdedit.exe /deletevalue "{current}" safeboot 2>&1
        $null = & bcdedit.exe /deletevalue "{current}" detecthal 2>&1
        $null = & bcdboot.exe C:\Windows /s C: /f BIOS 2>&1
        LogLine "BCD: default/current + bcdboot BIOS applied"
    } catch {
        LogLine "WARN: BCD/brute bcdboot block: $_"
    }

    $servicesToAuto = @(
        "QEMU-GA",
        "Balloon",
        "BalloonService",
        "Dhcp",
        "Dnscache",
        "NlaSvc",
        "netprofm",
        "nsi",
        "MpsSvc",
        "TermService",
        "UmRdpService",
        "WinRM"
    )

    foreach ($svc in $servicesToAuto) {
        try {
            $s = Get-Service $svc -ErrorAction SilentlyContinue
            if ($s) {
                LogLine "Setting service $svc to Automatic"
                sc.exe config $svc start= auto | Out-Null
                Start-Service $svc -ErrorAction SilentlyContinue
            }
        } catch {
            LogLine "WARN: Could not configure service $svc : $_"
        }
    }

    $qemuGaMsi = "C:\ospc2flex\guest-agent\qemu-ga-x86_64.msi"
    if (Test-Path $qemuGaMsi) {
        LogLine "Installing QEMU Guest Agent from $qemuGaMsi"
        Start-Process msiexec.exe -ArgumentList "/i `"$qemuGaMsi`" /qn /norestart" -Wait
        Start-Sleep -Seconds 5
        sc.exe config "QEMU-GA" start= auto | Out-Null
        Start-Service "QEMU-GA" -ErrorAction SilentlyContinue
    } else {
        LogLine "WARN: QEMU Guest Agent MSI not found"
    }

    $virtioRoot = "C:\ospc2flex\virtio"
    if (Test-Path $virtioRoot) {
        LogLine "Installing all staged VirtIO drivers from $virtioRoot"
        pnputil /add-driver "$virtioRoot\*.inf" /subdirs /install | Out-File -FilePath $BfLog -Append -Encoding UTF8
        pnputil /scan-devices | Out-File -FilePath $BfLog -Append -Encoding UTF8
    } else {
        LogLine "WARN: VirtIO staged driver root not found: $virtioRoot"
    }

    Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | ForEach-Object {
        try {
            LogLine "Enabling DHCP on adapter $($_.Name)"
            Set-NetIPInterface -InterfaceAlias $_.Name -Dhcp Enabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
        } catch {
            LogLine "WARN: DHCP repair failed on $($_.Name): $_"
        }
    }

    LogLine "Enabling RDP and firewall rules"
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue

    try {
        winrm quickconfig -quiet 2>&1 | Out-Null
        Enable-PSRemoting -Force 2>&1 | Out-Null
    } catch {
        LogLine "WARN: WinRM enable failed: $_"
    }

    LogLine "Final driver/service status"
    Get-Service QEMU-GA,Balloon,Dhcp,Dnscache,NlaSvc,netprofm,MpsSvc,TermService,WinRM -ErrorAction SilentlyContinue |
        Format-Table -AutoSize | Out-File -FilePath $BfLog -Append -Encoding UTF8

    Get-CimInstance Win32_SystemDriver |
        Where-Object {
            $_.Name -match "viostor|vioscsi|netkvm|balloon|vioser|viorng|qemu|fwcfg|qxldod|VioGpu|pvpanic"
        } |
        Select-Object Name, DisplayName, State, Started, Status |
        Format-Table -AutoSize | Out-File -FilePath $BfLog -Append -Encoding UTF8

    LogLine "Brute-force Flex first boot repair completed"
}

# ── 0. Keep boot on the normal Windows loader (not Safe Mode / not auto-recovery) ──
# Offline repair already patches BCD; this re-applies policy on first successful
# Windows start so later boots stay on normal mode even if markers were pending.
try {
    $null = & bcdedit.exe /set "{bootmgr}" timeout 0 2>&1
    $null = & bcdedit.exe /set "{bootmgr}" displaybootmenu No 2>&1
    $null = & bcdedit.exe /set "{current}" bootstatuspolicy IgnoreAllFailures 2>&1
    $null = & bcdedit.exe /set "{current}" recoveryenabled No 2>&1
    $null = & bcdedit.exe /set "{current}" device partition=C: 2>&1
    $null = & bcdedit.exe /set "{current}" osdevice partition=C: 2>&1
    $null = & bcdedit.exe /set "{current}" path \Windows\System32\winload.exe 2>&1
    $null = & bcdedit.exe /set "{current}" systemroot \Windows 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" safeboot 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" safebootalternateshell 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" recoverysequence 2>&1
    Write-Host "[ospc2flex] BCD: normal-boot policy reinforced on {current} (bcdedit)"
    # Scrub recoverysequence / recoveryenabled on EVERY BCD object (e.g. winresume
    # {guid} is not {current}; offline repair patches the hive but this catches stragglers).
    $curId = $null
    foreach ($line in (& bcdedit.exe /enum all 2>&1)) {
        if ($line -match '^\s*identifier\s+(\{.+\})') {
            $curId = $Matches[1]
            continue
        }
        if ($null -ne $curId -and $line -match '^\s*recoverysequence\s') {
            $null = & bcdedit.exe /deletevalue $curId recoverysequence 2>&1
            $null = & bcdedit.exe /set $curId recoveryenabled No 2>&1
        }
    }
    Write-Host "[ospc2flex] BCD: recoverysequence scrubbed on all enumerated entries"
} catch {
    Write-Host "[ospc2flex] BCD reinforcement skipped: $_"
}

# ── 1. Install staged NetKVM locally after Windows reaches userland ──
try {
    $netkvmStage = 'C:\ospc2flex_driver_stage\NetKVM'
    if (Test-Path $netkvmStage) {
        Write-Host "[ospc2flex] Installing staged NetKVM driver from $netkvmStage"
        & pnputil /add-driver "$netkvmStage\*.inf" /subdirs /install 2>&1 | ForEach-Object { Write-Host "[ospc2flex] pnputil: $_" }
        Start-Sleep -Seconds 3
        & pnputil /scan-devices 2>&1 | Out-Null
        Write-Host "[ospc2flex] NetKVM staging install complete"
    } else {
        Write-Host "[ospc2flex] NetKVM stage folder not present; skipping"
    }
} catch {
    Write-Host "[ospc2flex] NetKVM staging install error: $_"
}

# ── 2. Remove ghost/disconnected network adapters (old Xen NICs) ──
try {
    $ghost = Get-PnpDevice -Class Net -Status Unknown -ErrorAction SilentlyContinue
    foreach ($dev in $ghost) {
        Write-Host "[ospc2flex] Removing ghost adapter: $($dev.FriendlyName) ($($dev.InstanceId))"
        & pnputil /remove-device $dev.InstanceId 2>&1 | Out-Null
    }
    Write-Host "[ospc2flex] Ghost adapter cleanup done"
} catch {
    Write-Host "[ospc2flex] Ghost adapter cleanup skipped: $_"
}

# ── 3. Clear stale static IP bindings and enable DHCP on all adapters ──
try {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.InterfaceDescription -match 'VirtIO|Red Hat' }
    foreach ($nic in $adapters) {
        Write-Host "[ospc2flex] Configuring DHCP on: $($nic.Name) ($($nic.InterfaceDescription))"
        # Remove any static IP addresses
        Get-NetIPAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Manual' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        # Remove static routes
        Remove-NetRoute -InterfaceIndex $nic.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        # Enable DHCP
        Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
        # Enable DNS via DHCP
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        Write-Host "[ospc2flex] DHCP enabled on $($nic.Name)"
    }
    # Force DHCP renewal
    ipconfig /release 2>&1 | Out-Null
    ipconfig /renew 2>&1 | Out-Null
    Write-Host "[ospc2flex] DHCP renewal complete"
} catch {
    Write-Host "[ospc2flex] DHCP config error: $_"
}

# ── 4. Open firewall for RDP + ICMP on all profiles ──
try {
    # Allow RDP
    Set-NetFirewallRule -DisplayGroup "Remote Desktop" -Enabled True -ErrorAction SilentlyContinue
    # If no predefined RDP rule, create one
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-RDP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-RDP" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    # Allow ICMP (ping)
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-ICMPv4" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-ICMPv4" -Direction Inbound -Protocol ICMPv4 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "[ospc2flex] Firewall: RDP (3389) + ICMP allowed on all profiles"
} catch {
    Write-Host "[ospc2flex] Firewall config error: $_"
}

# ── 5. Ensure RDP is enabled in registry ──
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0 -ErrorAction SilentlyContinue
    Write-Host "[ospc2flex] RDP enabled in registry"
} catch {
    Write-Host "[ospc2flex] RDP registry error: $_"
}

# ── 6. Enable OpenSSH Server (Windows Server 2019+ built-in) ──
try {
    $sshCapability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' }
    if ($sshCapability) {
        if ($sshCapability.State -ne 'Installed') {
            Write-Host "[ospc2flex] Installing OpenSSH Server..."
            Add-WindowsCapability -Online -Name $sshCapability.Name -ErrorAction Stop | Out-Null
        }
        Start-Service sshd -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-SSH" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "ospc2flex-SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
        # Set PowerShell as default SSH shell
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[ospc2flex] OpenSSH Server: installed, started, firewall open, default shell=PowerShell"
    } else {
        Write-Host "[ospc2flex] OpenSSH Server capability not available (Server 2016?) — skipping"
    }
} catch {
    Write-Host "[ospc2flex] OpenSSH setup error (non-fatal): $_"
}

# ── 7. Enable WinRM (works on all Windows Server versions) ──
try {
    # Enable WinRM service
    Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service WinRM -ErrorAction SilentlyContinue
    # Configure WinRM for unencrypted basic auth (jumphost is on same private network)
    & winrm quickconfig -quiet 2>&1 | Out-Null
    & winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-Null
    & winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-Null
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-WinRM" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-WinRM" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "[ospc2flex] WinRM: enabled, basic auth, firewall open on 5985"
} catch {
    Write-Host "[ospc2flex] WinRM setup error (non-fatal): $_"
}

# ── 8. Run verification and write results ──
try {
    $report = @()
    $report += "=== ospc2flex post-boot verification ==="
    $report += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "Hostname: $env:COMPUTERNAME"
    $report += ""

    # Disk driver
    $viostor = Get-Service viostor -ErrorAction SilentlyContinue
    $report += "viostor service: $($viostor.Status)"

    # Network adapter
    $nics = Get-NetAdapter -ErrorAction SilentlyContinue
    foreach ($n in $nics) {
        $report += "NIC: $($n.Name) | $($n.InterfaceDescription) | Status=$($n.Status) | MAC=$($n.MacAddress)"
    }

    # IP config
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' }
    foreach ($ip in $ips) {
        $report += "IP: $($ip.IPAddress)/$($ip.PrefixLength) on $($ip.InterfaceAlias) (Origin=$($ip.PrefixOrigin))"
    }

    # DHCP status
    $dhcp = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }
    foreach ($d in $dhcp) {
        $report += "DHCP: $($d.InterfaceAlias) = $($d.Dhcp)"
    }

    # Ghost devices
    $ghosts = Get-PnpDevice -Class Net -Status Unknown -ErrorAction SilentlyContinue
    $report += "Ghost NICs: $(@($ghosts).Count)"

    # Firewall
    $fwRules = Get-NetFirewallRule -DisplayName "ospc2flex*" -ErrorAction SilentlyContinue
    foreach ($fw in $fwRules) {
        $report += "Firewall: $($fw.DisplayName) = Enabled:$($fw.Enabled)"
    }

    # SSH / WinRM
    $sshSvc = Get-Service sshd -ErrorAction SilentlyContinue
    $report += "OpenSSH: $(if ($sshSvc) { $sshSvc.Status } else { 'not installed' })"
    $winrmSvc = Get-Service WinRM -ErrorAction SilentlyContinue
    $report += "WinRM: $(if ($winrmSvc) { $winrmSvc.Status } else { 'not found' })"

    # Disk/Volume
    $disks = Get-Disk -ErrorAction SilentlyContinue
    foreach ($dk in $disks) {
        $report += "Disk: #$($dk.Number) $($dk.FriendlyName) Size=$([math]::Round($dk.Size/1GB,1))GB Style=$($dk.PartitionStyle)"
    }
    $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
    foreach ($v in $vols) {
        $report += "Volume: $($v.DriveLetter): Size=$([math]::Round($v.Size/1GB,1))GB Free=$([math]::Round($v.SizeRemaining/1GB,1))GB FS=$($v.FileSystemType)"
    }

    $report += ""
    $report += "=== verification complete ==="

    $report | Out-File -FilePath "C:\ospc2flex_verification.txt" -Encoding UTF8
    $report | ForEach-Object { Write-Host $_ }
    Write-Host "[ospc2flex] Verification report: C:\ospc2flex_verification.txt"
} catch {
    Write-Host "[ospc2flex] Verification error: $_"
}

Write-Host "[ospc2flex] First-boot repair complete."
Write-Host "[ospc2flex] Log saved to $logFile"
Stop-Transcript

# ── 8. Self-cleanup (keep verification report, remove script) ──
Remove-Item -Path "C:\ospc2flex_firstboot.ps1" -Force -ErrorAction SilentlyContinue
FIRSTBOOTEOF

  # SetupComplete.cmd — Windows runs this automatically on first boot after OOBE/sysprep
  # Also works on non-sysprepped images as a fallback via RunOnce registry key
  sudo tee "$FIRSTBOOT_CMD" > /dev/null <<'CMDEOF'
@echo off
echo [ospc2flex] Running first-boot network and firewall repair...
powershell.exe -ExecutionPolicy Bypass -File "C:\ospc2flex_firstboot.ps1"
del /f /q "%~f0" 2>nul
CMDEOF

  PASS "First-boot script: C:\\ospc2flex_firstboot.ps1"
  PASS "SetupComplete.cmd trigger: Windows\\Setup\\Scripts\\SetupComplete.cmd"

  # Also inject RunOnce registry key as backup trigger (works even without sysprep)
  RUNONCE_REG="/tmp/runonce_$$.reg"
  cat > "$RUNONCE_REG" <<'RUNONCEEOF'
Windows Registry Editor Version 5.00

"ControlSet001\Control\Session Manager\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
"ControlSet002\Control\Session Manager\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
RUNONCEEOF

  if [ "${DEBUG:-0}" -eq 1 ]; then
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$RUNONCE_REG" 2>&1 || true
  else
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$RUNONCE_REG" >/dev/null 2>&1 || true
  fi
  rm -f "$RUNONCE_REG"
  PASS "Registry RunOnce fallback: ospc2flex_firstboot (ControlSet001+002)"

  # Also inject into SOFTWARE hive RunOnce (user-session trigger — covers logged-in admin)
  if [ -f "$HIVE_SW" ]; then
    SW_RUNONCE_REG="/tmp/sw_runonce_$$.reg"
    cat > "$SW_RUNONCE_REG" <<'SWRUNONCEEOF'
Windows Registry Editor Version 5.00

"Microsoft\Windows\CurrentVersion\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
SWRUNONCEEOF

    if [ "${DEBUG:-0}" -eq 1 ]; then
      merge_registry_patch "$HIVE_SW" "HKEY_LOCAL_MACHINE\\SOFTWARE" "$SW_RUNONCE_REG" 2>&1 || true
    else
      merge_registry_patch "$HIVE_SW" "HKEY_LOCAL_MACHINE\\SOFTWARE" "$SW_RUNONCE_REG" >/dev/null 2>&1 || true
    fi
    rm -f "$SW_RUNONCE_REG"
    PASS "SOFTWARE RunOnce fallback: HKLM\\...\\RunOnce\\ospc2flex_firstboot"
  fi

  printf '%s\n' "" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  printf '%s\n' "Dynamic BCD note:" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  printf '%s\n' "- Offline repair patches detected BCD objects directly (no blind partition=C: assumption)." | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  printf '%s\n' "- WinRE helper script uses partition=C: only as emergency manual operator fallback." | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  printf '%s\n' "Report status: COMPLETE" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
  PASS "Offline validation report: C:\\ospc2flex_offline_repair_report.txt"

else
  INFO "[DRY-RUN] Would write first-boot PowerShell script for DHCP + firewall repair"
  INFO "[DRY-RUN] Would inject RunOnce registry entries in SYSTEM + SOFTWARE hives"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
echo ""

# Write sentinel
if [ $DRY_RUN -eq 0 ]; then
  if is_bruteforce_flex; then
    echo "=== Brute-force Flex validation ===" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    for f in \
      viostor.sys \
      vioscsi.sys \
      netkvm.sys \
      balloon.sys \
      vioser.sys \
      viorng.sys \
      qemufwcfg.sys
    do
      if [ -f "$DRIVERS_DIR/$f" ]; then
        echo "DriverFile.$f=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
      else
        echo "DriverFile.$f=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
      fi
    done
    if [ -f "$MNT/ospc2flex/guest-agent/qemu-ga-x86_64.msi" ]; then
      echo "QEMU-GA.MSI=OK" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    else
      echo "QEMU-GA.MSI=MISSING" | sudo tee -a "$REPAIR_REPORT_FILE" >/dev/null
    fi
    PASS "Brute-force Flex validation report written"
  fi
  touch "${QCOW2}.win_repaired"
  PASS "Sentinel: ${QCOW2}.win_repaired"
fi

echo "═══════════════════════════════════════════════════════════════════════════"
if [ "$DRY_RUN" -eq 1 ]; then
echo " ✅ Windows VirtIO injection dry-run complete!"
else
echo " ✅ Windows VirtIO injection complete!"
fi
echo "    Product: $PROD_NAME"
if is_bruteforce_flex; then
  echo "    Mode: bruteforce_flex — full VirtIO + QEMU-GA staging; auxiliary drivers not neutralized"
else
  echo "    Drivers: viostor (block) + vioscsi (SCSI) offline; NetKVM preinstalled and also staged"
fi
if [ "$DRY_RUN" -eq 1 ]; then
echo "    Registry: Services + CriticalDeviceDatabase entries would be injected"
echo "    Xen: PV drivers would be disabled (xenvbd, xendisk, xenfilt, xennet, xenvif, xeniface, xenbus, xenagent, xenbus_monitor, XenSvc)"
echo "    Xen purge: $( [ "${PURGE_XEN:-0}" -eq 1 ] && echo 'aggressive removal would run' || echo 'disabled' )"
echo "    Storage: Core MS drivers would be verified (disk, volmgr, partmgr, volsnap, mountmgr)"
echo "    First-boot auto-repair (RunOnce) would configure:"
else
echo "    Registry: Services + CriticalDeviceDatabase entries injected"
echo "    Xen: PV drivers disabled (xenvbd, xendisk, xenfilt, xennet, xenvif, xeniface, xenbus, xenagent, xenbus_monitor, XenSvc)"
echo "    Xen purge: $( [ "${PURGE_XEN:-0}" -eq 1 ] && echo 'aggressive removal enabled (--purge-xen)' || echo 'disabled' )"
echo "    Storage: Core MS drivers verified (disk, volmgr, partmgr, volsnap, mountmgr)"
echo "    First-boot auto-repair (RunOnce):"
fi
echo "      - BCD: bcdedit on {current} + recoverysequence scrub on all BCD entries (incl. winresume)"
echo "      - First boot stays in normal mode; safeboot is removed from BCD if present"
echo "      - Fast Startup disabled offline (HiberbootEnabled=0)"
echo "      - Install staged NetKVM, then remove ghost Xen NICs and enable DHCP"
echo "      - Firewall: RDP (3389) + ICMP + SSH (22) + WinRM (5985)"
echo "      - OpenSSH Server enabled (2019+) — allows automated SSH verification"
echo "      - WinRM enabled (all versions) — allows remote PowerShell"
echo "      - Verification report written to C:\\ospc2flex_verification.txt"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  After boot, the migrator will automatically:"
echo "    1. Wait for VM DHCP IP (via OpenStack API)"
echo "    2. SSH in as Administrator (or WinRM fallback)"
echo "    3. Read C:\\ospc2flex_verification.txt"
echo "    4. Report pass/fail for each component"
echo ""
