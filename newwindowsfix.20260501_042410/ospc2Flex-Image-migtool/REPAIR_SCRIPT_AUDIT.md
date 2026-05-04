# Repair Script Audit: ospc2flex_offline_repair.sh v2.1

**Date:** April 21, 2026  
**Scope:** Complete OS-specific repair sections + common repairs  
**Status:** Flagging issues without implementing fixes (awaiting approval)

---

## Executive Summary

| Total Issues Found | Critical | High | Medium | Low |
|----|----------|------|--------|-----|
| **18** | 3 | 5 | 7 | 3 |

---

## UBUNTU 20/22/24 Audit

### Issue #1: `GRUB_CMDLINE_LINUX_DEFAULT` Override Risk
**Severity:** MEDIUM  
**Location:** Lines ~370-375  
**Problem:**  
```bash
echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
```
If grub already has `GRUB_CMDLINE_LINUX_DEFAULT` with values (e.g., `quiet splash`), this appends an empty line instead of replacing it. Result: Two conflicting definitions, second wins (okay) but untidy.

**Impact:** Low risk (empty wins), but inelegant  
**Proposed Fix:**  
```bash
# Remove existing GRUB_CMDLINE_LINUX_DEFAULT BEFORE appending
sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' "$MNT/etc/default/grub"
echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
```

---

### Issue #2: grub.cfg Regex May Miss Some Boot Lines
**Severity:** MEDIUM  
**Location:** Lines ~383-391  
**Problem:**  
```bash
sudo sed -i '/^\s*linux\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}' "$_gcfg"
```
The regex `/^\s*linux\s.*root=/` requires `root=` to be present. Some GRUB configs use:
- `linux16` (legacy BIOS)
- `linuxefi` (UEFI)
- Boot params after `root=` on different line (rare)

**Impact:** May miss some older GRUB entries on legacy BIOS systems  
**Proposed Fix:**  
```bash
# More comprehensive regex:
sudo sed -i '/^\s*linux[16efi]*\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}' "$_gcfg"
# Or handle separately:
for _kw in linux linux16 linuxefi; do
  sudo sed -i "/^\s*$_kw\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}" "$_gcfg"
done
```

---

### Issue #3: Missing `/etc/default/grub` Handling
**Severity:** LOW  
**Location:** Lines ~372-378  
**Problem:**  
If `/etc/default/grub` doesn't exist, no error is logged (bash continues). Grub parameters are then only patched in grub.cfg directly, which is good, but admin won't know the config file is missing.

**Impact:** Silent partial fix  
**Proposed Fix:**  
```bash
if [ -f "$MNT/etc/default/grub" ]; then
  # ...existing code...
else
  WARN "/etc/default/grub not found — grub params only patched in grub.cfg"
fi
```

---

## DEBIAN 10/11/12 Audit

### Issue #4: **CRITICAL** — Debian 12 Netplan Detection Logic Flaw
**Severity:** CRITICAL  
**Location:** Lines ~419-424  
**Problem:**  
```bash
if [ "${OS_MAJOR:-0}" -ge 12 ] || \
   ( [ -d "$MNT/usr/share/netplan" ] && ! dpkg --root="$MNT" -l ifupdown 2>/dev/null | grep -q '^ii' ); then
```
The `dpkg` check is unreliable because:
1. `dpkg --root` might fail in chroot with missing dpkg state
2. If ifupdown is in `rc` (removed but config present), grep won't match `^ii` (installed)
3. Complex boolean logic: `!( A && B )` = ` !A || !B` → might apply netplan when should use ifupdown

**Impact:** CRITICAL - Debian 12 may incorrectly get ifupdown or Debian 11 gets netplan  
**Proposed Fix:**  
```bash
# Simplified: OS version is definitive source
if [ "${OS_MAJOR:-0}" -ge 12 ]; then
  INFO "Debian $OS_MAJOR → netplan (version >= 12)"
  # netplan logic
else
  INFO "Debian $OS_MAJOR → ifupdown (version < 12)"
  # ifupdown logic
fi
```

---

### Issue #5: Debian 10/11 Lacks `/boot/efi` Handling
**Severity:** MEDIUM  
**Location:** Lines ~450-465 (Debian section)  
**Problem:**  
Script doesn't mount `/boot/efi` for Debian systems. Comments say "root=vda1(ext4,PARTUUID), /boot/efi=vda15" but no code handles separate EFI partition.

**Impact:** Systems with separate EFI partition won't repair boot config correctly  
**Proposed Fix:**  
```bash
# Add after grub.cfg patching:
if [ -b "${NBD_DEV}p15" ]; then
  INFO "Debian: detected separate /boot/efi partition (vda15)"
  sudo mkdir -p "$MNT/boot/efi"
  sudo mount "${NBD_DEV}p15" "$MNT/boot/efi" && PASS "Mounted /boot/efi" || true
fi
```

---

### Issue #6: Grub Serial Terminal Not Set for Debian
**Severity:** HIGH  
**Location:** Lines ~441-465 (Debian grub section)  
**Problem:**  
Script sets `GRUB_CMDLINE_LINUX` but DOES NOT set `GRUB_TERMINAL="console serial"` for Debian (unlike RHEL-family). Missing serial output blocks FLEX console/VNC logs.

**Impact:** HIGH - VNC/serial console won't show boot messages, hard to debug boot issues  
**Proposed Fix:**  
```bash
# After GRUB_CMDLINE_LINUX lines, add:
sudo sed -i '/^.*GRUB_TERMINAL=/d' "$MNT/etc/default/grub"
echo 'GRUB_TERMINAL="console serial"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
```

---

## RHEL-FAMILY (AlmaLinux, Rocky, CentOS, RHEL) Audit

### Issue #7: RHEL /boot Hardcoding — All Empty Strings
**Severity:** HIGH  
**Location:** Lines ~543-557  
**Problem:**  
```bash
case "$OS_ID_FROM_ARG" in
  almalinux) BOOT_PART=""; BOOTEFI_PART="" ;;  # EMPTY!
  rocky)     BOOT_PART=""; BOOTEFI_PART="" ;;
  centos|rhel) BOOT_PART=""; BOOTEFI_PART="" ;;
```
All hardcoded to empty strings, so boot mounting always skipped. Code then tries UUID fallback which may fail on missing/corrupted fstab.

**Impact:** HIGH - BLS loader entries & grubenv NOT updated. VM boots with old NIC names (eth fails).  
**Proposed Fix:**  
```bash
# RHEL systems have /boot ON ROOT (not separate), so:
case "$OS_ID_FROM_ARG" in
  almalinux|rocky|rhel) 
    # /boot is on root — no separate partition
    BOOT_PART=""
    BOOTEFI_PART=""
    INFO "RHEL-family: /boot is ON ROOT partition (no separate mount needed)"
    # But still update BLS in root/$MNT/boot/loader/entries
    ;;
  centos) 
    # CentOS 7: traditional grub (not BLS), /boot on root
    BOOT_PART=""
    ;;
esac
```
Then restructure BLS update logic to work without mounting.

---

### Issue #8: BLS Update Logic Assumes /boot is Mounted
**Severity:** CRITICAL  
**Location:** Lines ~579-600  
**Problem:**  
```bash
if [ -n "$BOOT_PART" ] && [ $DRY_RUN -eq 0 ]; then
  sudo mount ... "$BOOT_PART" "$MNT/boot" ...
  # BLS update happens INSIDE this if block
  if [ -d "$MNT/boot/loader/entries" ]; then
    # Update BLS
```
Since `$BOOT_PART` is always empty (Issue #7), this entire block is SKIPPED. BLS entries are never updated.

**Impact:** CRITICAL - AlmaLinux 9 / Rocky 8/9 VMs boot with `biosdevname=1` (ens* naming), SSH fails on FLEX  
**Proposed Fix:**  
```bash
# Don't require mounting — just update files in $MNT directly:
echo "── [RHEL-FAMILY] Update BLS loader entries ──────────────────────────────"
if [ -d "$MNT/boot/loader/entries" ]; then
  for _conf in "$MNT/boot/loader/entries"/*.conf; do
    [ -f "$_conf" ] || continue
    # ... existing update logic, but reference $_conf directly ...
  done
else
  INFO "No BLS entries found (CentOS 7 uses traditional grub)"
fi
```

---

### Issue #9: grubenv Path Assumptions May Fail
**Severity:** HIGH  
**Location:** Lines ~602-620 (grubenv update)  
**Problem:**  
```bash
for _grubenv in \
  "$MNT/boot/grub2/grubenv" \
  "$MNT/boot/efi/EFI/almalinux/grubenv" \
  "$MNT/boot/efi/EFI/rocky/grubenv" \
```
Script tries multiple hardcoded paths, but doesn't verify which one actually exists. If `/boot/efi` is not mounted (Issue #7), the EFI paths will never be found/updated. Then `sed` exits cleanly (file doesn't exist), but update silently skips.

**Impact:** HIGH - EFI boot may retain old kernel params  
**Proposed Fix:**  
```bash
# Add verification:
for _grubenv in ...; do
  if [ -f "$_grubenv" ]; then
    # ... update logic ...
    PASS "Updated grubenv: $(basename $_grubenv)"
  fi
done
# Log if NO grubenv found:
if [ "$_grubenv_count" -eq 0 ]; then
  WARN "No grubenv files found — kernel params may not be updated for EFI boot"
fi
```

---

### Issue #10: NetworkManager DHCP Timeout May Be Too Short
**Severity:** MEDIUM  
**Location:** Lines ~533 (RHEL NM keyfile)  
**Problem:**  
```bash
[ipv4]
dhcp-timeout=90
method=auto
```
90 seconds is reasonable but may timeout on slow FLEX metadata server. OSPC/Rackspace had faster metadata service.

**Impact:** MEDIUM - On slow FLEX deployments, DHCP times out before IP acquired  
**Proposed Fix:**  
```bash
# Increase timeout:
dhcp-timeout=180  # 3 minutes, more forgiving
# Or add retry:
dhcp-send-hostname=yes
ipv6-privacy=unknown
```

---

### Issue #11: CentOS 7 Dracut Virtio Check May Fail Silently
**Severity:** MEDIUM  
**Location:** Lines ~674-690 (CentOS virtio injection)  
**Problem:**  
```bash
if find "$MNT/lib/modules/$_kver" -name 'virtio_blk*' 2>/dev/null | grep -q .; then
  # run dracut
else
  WARN "virtio_blk module not found..."
```
If kernel version detection fails or `/lib/modules` structure is non-standard, this check may incorrectly think virtio is not available. Then dracut is not run, and VM fails to boot on FLEX KVM.

**Impact:** MEDIUM - CentOS 7 VMs won't boot on FLEX (no virtio drivers)  
**Proposed Fix:**  
```bash
# More robust check:
if [ ! -d "$MNT/lib/modules/$_kver" ]; then
  WARN "No kernel modules for $_kver"
  # Try to force dracut anyway
  sudo chroot "$MNT" /usr/sbin/dracut --force 2>/dev/null && PASS "dracut forced" || WARN "dracut failed"
fi
```

---

### Issue #12: CentOS 7 grub2-mkconfig May Regenerate Old Config
**Severity:** MEDIUM  
**Location:** Lines ~713-725 (CentOS grub rebuild)  
**Problem:**  
```bash
sudo chroot "$MNT" /usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg
```
If `/etc/default/grub` still has stale `GRUB_CMDLINE_LINUX` values (e.g., `rhgb quiet`), grub2-mkconfig will regenerate using OLD params, undoing the net.ifnames=0 patch.

**Impact:** MEDIUM - VM boots but fails to get IP (old NIC naming)  
**Proposed Fix:**  
```bash
# Before running grub2-mkconfig, clean /etc/default/grub:
sudo sed -i 's/rhgb //g; s/ rhgb//g; s/quiet //g; s/ quiet//g' "$MNT/etc/default/grub"
# Then patch in new params:
sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="net.ifnames=0 console=ttyS0"/' "$MNT/etc/default/grub"
# THEN run grub2-mkconfig
```

---

## ALL OS: Common Repairs Audit

### Issue #13: fstab xvda→vda Regex May Miss Some Cases
**Severity:** MEDIUM  
**Location:** Lines ~785-790 (fstab cleanup)  
**Problem:**  
```bash
sudo sed -i 's|/dev/xvda|/dev/vda|g' "$MNT/etc/fstab"
```
This is a simple find/replace, but what if fstab has:
- `/dev/xvda1p1` (partition on partition — unlikely but possible)
- Paths in comments that mention xvda
- Environment variables like `$XVDA_ROOT`

**Impact:** LOW - These are rare edge cases  
**Proposed Fix:**  
```bash
# More specific regex:
sudo sed -i 's|/dev/xvda\([0-9]\)|/dev/vda\1|g' "$MNT/etc/fstab"
# This ensures only /dev/xvda<digit> → /dev/vda<digit>
```

---

### Issue #14: **CRITICAL** — fstab Comment Regex Breaks on Comments
**Severity:** CRITICAL  
**Location:** Lines ~800-809 (fstab non-root line filtering)  
**Problem:**  
```bash
sudo sed -i \
  '/^[[:space:]]*#/b;           # Skip existing comments
   ...
   /^\/dev\//s|^|# [ospc2flex] |' \  # Comment non-root /dev/* lines
  "$MNT/etc/fstab"
```
If `/dev/` line already starts with spaces or special chars, the regex won't match. More critically, the sed script has a logic bug: it comments out **all** `/dev/*` lines that don't match the whitelist. But the whitelist includes:
- `/[[:space:]]\/[[:space:]]/b;` (mount point surrounded by spaces) — good
- `/\/dev\/vd[a-z][0-9]*[[:space:]]*\/[[:space:]]/b;` (vda* with root mount) — good

BUT this misses: `/dev/vda1 /boot ext4` (no extra spaces around `/boot`).

**Impact:** CRITICAL - Root partition and /boot partitions may be COMMENTED OUT, making filesystem read-only or unbootable!

**Example:**  
```
# Original:
/dev/xvda1 / ext4 defaults 0 1
/dev/xvda2 /boot ext4 defaults 0 1

# After sed with bug:
# [ospc2flex] /dev/vda1 / ext4 defaults 0 1
# [ospc2flex] /dev/vda2 /boot ext4 defaults 0 1
```

**Proposed Fix:**  
```bash
# Rewrite the logic more carefully:
sudo awk '
  /^[[:space:]]*#/ { print; next }  # Keep existing comments
  /^[[:space:]]*$/ { print; next }  # Keep blank lines
  /LABEL=/ || /UUID=/ || /PARTUUID=/ { print; next }  # Keep LABEL/UUID
  /[[:space:]]\/$/ || /[[:space:]]\/boot/ || /[[:space:]]\/boot\/efi/ { print; next }  # Keep mount points
  /^\/dev\// { print "# [ospc2flex] " $0; next }  # Comment /dev/* lines
  { print }  # Keep everything else
' "$MNT/etc/fstab" | sudo tee "$MNT/etc/fstab.new" >/dev/null
sudo mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
```

---

### Issue #15: grub xvda→vda Rename May Break Root Boot
**Severity:** HIGH  
**Location:** Lines ~839-856 (grub xvda→vda rename)  
**Problem:**  
```bash
sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_gcfg"
```
Simple replace, but if grub.cfg has UUID= or PARTUUID= boot lines (which are better), the sed does nothing. If it has `root=/dev/xvda1` inline in kernel params (not on separate line), this works. But if kernel params span multiple lines or are in variables, the replace may fail silently.

**Impact:** HIGH - Kernel still boots with root=/dev/xvda1 → initramfs fails to find root  
**Proposed Fix:**  
```bash
# Verify the change took effect:
if grep -q 'xvda' "$_gcfg" 2>/dev/null; then
  sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_gcfg"
  if grep -q 'xvda' "$_gcfg"; then
    WARN "xvda still present in $_gcfg after sed — manual review needed"
  else
    PASS "$(basename $_gcfg): /dev/xvda → /dev/vda"
  fi
fi
```

---

### Issue #16: Cloud-init Debian Datasource Config Has Wrong Format
**Severity:** MEDIUM  
**Location:** Lines ~956-967 (cloud-init datasource)  
**Problem:**  
```yaml
datasource:
  OpenStack:
    metadata_urls:
      - http://169.254.169.254
```
This YAML syntax is for newer cloud-init (>=20.x). Debian 10/11 ship older cloud-init (<=19.x) which uses different config format.

**Impact:** MEDIUM - Old cloud-init may not parse the config correctly, ignoring datasource setting  
**Proposed Fix:**  
```bash
# Check cloud-init version first:
_ci_ver=$(chroot "$MNT" cloud-init --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
if echo "$_ci_ver" | awk -F. '{exit !($1 >= 20)}'; then
  # New format (>=20.x)
  ...current YAML...
else
  # Old format (<20.x) — simpler:
  cat > /etc/cloud/cloud.cfg.d/99-flex.cfg <<'EOF'
datasource_list: [OpenStack]
EOF
fi
```

---

### Issue #17: SSH Key Generation May Fail on SELinux
**Severity:** MEDIUM  
**Location:** Lines ~1007-1030 (SSH key generation)  
**Problem:**  
```bash
sudo ssh-keygen -t rsa -b 2048 -f "$MNT/etc/ssh/ssh_host_rsa_key" -N "" -q
```
On RHEL-family, ssh-keygen runs as root in the host system, but generates keys with host SELinux context. When RHEL VM boots, `/.autorelabel` will fix context, but there's a window where sshd can't read the key (permission denied).

**Impact:** MEDIUM - SSH may be unavailable after FLEX VM first boot (until autorelabel complete)  
**Proposed Fix:**  
```bash
# For RHEL, generate in chroot context or explicitly label:
if [ "$OS_ID" = "almalinux" ] || [ "$OS_ID" = "rocky" ]; then
  # Pre-generate inside chroot to get correct SELinux context
  sudo chroot "$MNT" ssh-keygen -t rsa -b 2048 -f /etc/ssh/ssh_host_rsa_key -N "" -q
  # Or explicitly relabel:
  sudo chroot "$MNT" restorecon -v /etc/ssh/ssh_host_*_key 2>/dev/null || true
fi
```

---

### Issue #18: UFW Disable Logic Only Works if ufw.conf Exists
**Severity:** LOW  
**Location:** Lines ~963-967 (UFW disable)  
**Problem:**  
```bash
if [ -d "$MNT/etc/ufw" ]; then
  ...
  if [ -f "$MNT/etc/ufw/ufw.conf" ]; then
    sudo sed -i 's/^ENABLED=yes/ENABLED=no/' "$MNT/etc/ufw/ufw.conf"
  fi
```
If ufw is installed but `ufw.conf` is missing or ENABLED key is missing, UFW won't be disabled. Then on FLEX boot, UFW may activate and block traffic.

**Impact:** LOW - Unlikely but possible  
**Proposed Fix:**  
```bash
if [ -f "$MNT/etc/ufw/ufw.conf" ]; then
  if grep -q '^ENABLED=' "$MNT/etc/ufw/ufw.conf"; then
    sudo sed -i 's/^ENABLED=yes/ENABLED=no/' "$MNT/etc/ufw/ufw.conf"
  else
    echo "ENABLED=no" | sudo tee -a "$MNT/etc/ufw/ufw.conf" >/dev/null
  fi
else
  WARN "ufw.conf not found — UFW may not be disabled"
fi
```

---

## Summary Table: Issues by Severity

| # | OS | Severity | Category | Issue | Proposed Fix Complexity |
|---|-----|----------|----------|-------|----------------------|
| 1 | Ubuntu | MEDIUM | Config | GRUB_CMDLINE_LINUX_DEFAULT override | Low |
| 2 | Ubuntu | MEDIUM | Regex | grub.cfg regex misses linux16/linuxefi | Low |
| 3 | Ubuntu | LOW | Error Handling | Missing /etc/default/grub warning | Low |
| 4 | Debian | **CRITICAL** | Logic | Debian 12 netplan detection flaw | Medium |
| 5 | Debian | MEDIUM | Missing Feature | No /boot/efi handling | Medium |
| 6 | Debian | HIGH | Config | Missing GRUB_TERMINAL for serial | Low |
| 7 | RHEL | HIGH | Hardcoding | All BOOT_PART hardcoded empty | Medium |
| 8 | RHEL | **CRITICAL** | Logic | BLS update skipped (needs mounting fix) | High |
| 9 | RHEL | HIGH | Path | grubenv paths may fail silently | Low |
| 10 | RHEL | MEDIUM | Config | NM DHCP timeout too short | Low |
| 11 | CentOS | MEDIUM | Logic | Dracut virtio check unreliable | Medium |
| 12 | CentOS | MEDIUM | Config | grub2-mkconfig regenerates old config | Medium |
| 13 | All | MEDIUM | Regex | fstab xvda→vda may miss cases | Low |
| 14 | All | **CRITICAL** | Regex | fstab comment logic breaks root FS | High |
| 15 | All | HIGH | Logic | grub xvda→vda rename may fail silently | Medium |
| 16 | All | MEDIUM | Config | Cloud-init YAML format incompatible | Medium |
| 17 | All | MEDIUM | SELinux | SSH keys generated before context fixed | Medium |
| 18 | All | LOW | Config | UFW disable incomplete | Low |

---

## Recommendations

### Immediate Action (Before Next Migration Run)
- **Issue #14 (CRITICAL)** — fstab comment logic must be fixed before production use
- **Issue #8 (CRITICAL)** — BLS update bypass will cause all RHEL migrations to fail on FLEX

### High Priority (Next 24 hours)
- **Issue #4** — Debian 12 netplan detection
- **Issue #6** — Debian grub serial terminal
- **Issue #7** — RHEL boot partition hardcoding
- **Issue #15** — grub xvda→vda verification

### Medium Priority (This week)
- All remaining issues

### Testing Strategy
1. **Unit tests**: Create minimal test VMs for each OS + run repair with `--dry-run`
2. **Integration tests**: Export OSPC image → repair → boot on FLEX → verify SSH + networking
3. **Regression tests**: Re-run debian11new, dbian10new, dbian12 after fixes

---

## Files Modified by This Audit
- None yet (flagging only, awaiting approval)

**Next Step:** User approval to implement fixes (specify priority or all)
