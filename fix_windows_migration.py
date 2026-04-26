#!/usr/bin/env python3
"""
Windows Glance Migration Fix — Comprehensive Patch Script
Applies ALL fixes needed for Windows VM migration via the NBD dashboard.

Changes:
  1. [app.py] _stage_scripts_on_jumphost: accept ospc_creds, generate /tmp/ospc2flex_ospc.sh
  2. [app.py] nbd_run_single: extract ospc_creds from request, pass to staging
  3. [app.py] log_path: sanitize label so spaces don't break shell redirects
  4. [image_migrator.html] NBD payload: add ospc_creds object
  5. [ospc2flex_image_migrator.py] fsck -y -f (forced check)
  6. [ospc2flex_offline_repair.sh] fsck -y -f (forced check)

Golden rule: backs up every file before touching it.
"""
import os, shutil, datetime, sys

BASE = "/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current"
BACKUP_DIR = os.path.join(BASE, "backups")
os.makedirs(BACKUP_DIR, exist_ok=True)

TS = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')

def backup(filepath):
    basename = os.path.basename(filepath)
    name, ext = os.path.splitext(basename)
    dest = os.path.join(BACKUP_DIR, f"{name}_{TS}{ext}")
    shutil.copy2(filepath, dest)
    print(f"  BACKUP: {basename} → backups/{name}_{TS}{ext}")

def patch_file(filepath, patches, desc):
    """Apply a list of (old, new) string replacements to a file."""
    print(f"\n{'='*60}")
    print(f"PATCHING: {os.path.basename(filepath)}")
    print(f"  {desc}")
    
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    
    original = content
    for i, (old, new) in enumerate(patches):
        if old not in content:
            print(f"  SKIP patch #{i+1}: anchor not found (may already be applied)")
            continue
        content = content.replace(old, new, 1)
        print(f"  OK patch #{i+1}: applied")
    
    if content == original:
        print(f"  NO CHANGES (all patches already applied or skipped)")
        return False
    
    backup(filepath)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  SAVED ✅")
    return True

# ============================================================
# 1. app.py — staging function signature
# ============================================================
APP_PY = os.path.join(BASE, "workflow_dashboard", "app.py")

patch_file(APP_PY, [
    # 1a. Add ospc_creds param to staging function
    (
        "def _stage_scripts_on_jumphost(jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base):",
        "def _stage_scripts_on_jumphost(jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base, ospc_creds=None):"
    ),
], "Add ospc_creds parameter to staging function")

# 1b. Add OSPC creds staging block after flex creds upload
# Find the end of the flex creds SCP block
with open(APP_PY, "r", encoding="utf-8") as f:
    content = f.read()

FLEX_SCP_END = "    os.unlink(tf_path)\n\n    # 2. Worker script"
OSPC_STAGING_BLOCK = """    os.unlink(tf_path)

    # 1b. ALWAYS stage OSPC creds (needed by Windows Glance pipeline)
    if ospc_creds and (ospc_creds.get('username') or ospc_creds.get('apikey')):
        ospc_sh = "#!/usr/bin/env bash\\n"
        ospc_region = ospc_creds.get('region', 'IAD') or 'IAD'
        ospc_sh += f"export OS_REGION_NAME={shlex.quote(ospc_region)}\\n"
        ospc_sh += "export OS_NO_CACHE=1\\n"
        ospc_username = ospc_creds.get('username', '') or ''
        ospc_apikey = ospc_creds.get('apikey', '') or ''
        ospc_sh += f"export OS_USERNAME={shlex.quote(ospc_username)}\\n"
        ospc_sh += f"export OS_PASSWORD={shlex.quote(ospc_apikey)}\\n"
        ospc_sh += f"export OS_API_KEY={shlex.quote(ospc_apikey)}\\n"
        ospc_auth_url = ospc_creds.get('auth_url', '') or 'https://identity.api.rackspacecloud.com/v2.0/'
        ospc_sh += f"export OS_AUTH_URL={shlex.quote(ospc_auth_url)}\\n"
        ospc_account_id = ospc_creds.get('account_id', '') or ''
        if ospc_account_id:
            ospc_sh += f"export OS_TENANT_ID={shlex.quote(ospc_account_id)}\\n"
            ospc_sh += f"export OS_PROJECT_ID={shlex.quote(ospc_account_id)}\\n"
        with tempfile.NamedTemporaryFile(mode='w', suffix='.sh', delete=False) as tf:
            tf.write(ospc_sh); to_path = tf.name
        subprocess.run(["scp", "-i", ssh_key, "-o", "StrictHostKeyChecking=no",
                        to_path, f"{jumphost_user}@{jumphost_ip}:/tmp/ospc2flex_ospc.sh"],
                       check=True, timeout=30)
        os.unlink(to_path)

    # 2. Worker script"""

if 'ospc2flex_ospc.sh' not in content:
    if FLEX_SCP_END in content:
        backup(APP_PY)
        content = content.replace(FLEX_SCP_END, OSPC_STAGING_BLOCK, 1)
        print("\n  OK: Injected OSPC creds staging block")
    else:
        print("\n  WARNING: Could not find flex SCP anchor for OSPC block injection")
else:
    print("\n  SKIP: OSPC staging block already present")

# 1c. Extract ospc_creds from request in nbd_run_single
if "ospc_creds    = req.get('ospc_creds')" not in content:
    content = content.replace(
        "    flex_creds    = req.get('flex_creds') or {}\n\n    if not jumphost_ip:",
        "    flex_creds    = req.get('flex_creds') or {}\n    ospc_creds    = req.get('ospc_creds') or {}\n\n    if not jumphost_ip:",
        1
    )
    print("  OK: Added ospc_creds extraction in nbd_run_single")
else:
    print("  SKIP: ospc_creds extraction already present")

# 1d. Pass ospc_creds to staging call
if "ospc_creds=ospc_creds" not in content:
    content = content.replace(
        "                jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base\n            )",
        "                jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base,\n                ospc_creds=ospc_creds\n            )",
        1
    )
    print("  OK: Passing ospc_creds to staging function")
else:
    print("  SKIP: ospc_creds already passed to staging")

# 1e. Sanitize log_path
import re as _re
old_logpath = '    log_path = f"/tmp/mig_{label}.log"'
new_logpath = '    log_path = "/tmp/mig_{}.log".format(re.sub(r\'[^a-zA-Z0-9_.-]\', \'_\', label))'
if old_logpath in content:
    content = content.replace(old_logpath, new_logpath)
    count = content.count(new_logpath)
    print(f"  OK: Sanitized {count} log_path definition(s)")
else:
    print("  SKIP: log_path already sanitized")

# 1f. Quote kill_stale redirect
if 'f"> {log_path}"' in content:
    content = content.replace('f"> {log_path}"', "f\"> '{log_path}'\"")
    print("  OK: Quoted kill_stale_cmd redirect")

with open(APP_PY, "w", encoding="utf-8") as f:
    f.write(content)
print("  SAVED app.py ✅")

# ============================================================
# 2. image_migrator.html — add ospc_creds to NBD payload
# ============================================================
HTML = os.path.join(BASE, "workflow_dashboard", "templates", "image_migrator.html")

with open(HTML, "r", encoding="utf-8") as f:
    html = f.read()

if "ospc_creds:" not in html:
    ANCHOR = "flex_creds:    flexCreds,"
    INJECT_AFTER = """flex_creds:    flexCreds,
                        ospc_creds: {
                            username:   document.getElementById('ospc_cloud_user')?.value || '',
                            apikey:     document.getElementById('ospc_cloud_key')?.value || '',
                            account_id: document.getElementById('ospc_cloud_account')?.value || '',
                            region:     'IAD',
                            auth_url:   'https://identity.api.rackspacecloud.com/v2.0/'
                        },"""
    if ANCHOR in html:
        backup(HTML)
        html = html.replace(ANCHOR, INJECT_AFTER, 1)
        with open(HTML, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"\nPATCHED: image_migrator.html — added ospc_creds to NBD payload ✅")
    else:
        print(f"\nWARNING: flex_creds anchor not found in HTML")
else:
    print(f"\nSKIP: image_migrator.html — ospc_creds already present")

# ============================================================
# 3. ospc2flex_image_migrator.py — fsck -y -f
# ============================================================
MIGRATOR = os.path.join(BASE, "ospc2Flex-Image-migtool", "ospc2flex_image_migrator.py")
if os.path.isfile(MIGRATOR):
    patch_file(MIGRATOR, [
        ('sudo fsck -y "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true',
         'sudo fsck -y -f "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true'),
        ('sudo fsck -y "$_rpart2" >/dev/null 2>&1 || true',
         'sudo fsck -y -f "$_rpart2" >/dev/null 2>&1 || true'),
    ], "Force fsck to repair torn ext4 journals from unquiesced snapshots")

# ============================================================
# 4. ospc2flex_offline_repair.sh — fsck -y -f
# ============================================================
REPAIR = os.path.join(BASE, "ospc2Flex-Image-migtool", "ospc2flex_offline_repair.sh")
if os.path.isfile(REPAIR):
    with open(REPAIR, "r", encoding="utf-8") as f:
        repair_content = f.read()
    if 'fsck -y "$ROOT_PART"' in repair_content and 'fsck -y -f' not in repair_content:
        patch_file(REPAIR, [
            ('fsck -y "$ROOT_PART"', 'fsck -y -f "$ROOT_PART"'),
        ], "Force fsck in offline repair script")
    else:
        print(f"\nSKIP: offline_repair.sh — fsck already forced or pattern not found")

print("\n" + "="*60)
print("ALL PATCHES COMPLETE")
print("="*60)
