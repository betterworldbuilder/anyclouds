# ospc2flex_image_migrator

Bridge tool to turn an **OSPC VM** into a **FLEX-bootable test image and VM**, then optionally apply the most common Linux guest repairs automatically.

This tool is for the **image portability / first-boot remediation** stage of an OSPC → FLEX migration.

It automates:

1. Create snapshot image in OSPC
2. Export image from OSPC
3. Inspect image with `qemu-img`
4. Convert image to a FLEX-friendly format, usually `qcow2`
5. Import image into FLEX Glance
6. Optionally boot a FLEX test VM from that image
7. Optionally SSH into that VM and apply common guest fixes

It is a **bridge utility**, not a full production migration orchestrator.

---

## What problem it solves

When you snapshot a VM from OSPC and try to use it on FLEX, the image often needs two kinds of work:

### Outside the guest
- export snapshot from OSPC
- inspect the image format
- convert to a FLEX-acceptable format
- import into FLEX
- boot a test instance

### Inside the guest
- rebuild initramfs / boot artifacts
- fix `/etc/fstab`
- fix NIC naming / netplan
- clean `cloud-init`
- install `qemu-guest-agent`
- update old OSPC endpoints in app configs
- restart services and validate

This tool combines both flows into one CLI.

---

## What it does

### Image flow
- `openstack server image create`
- waits for OSPC snapshot image to become `active`
- `openstack image save`
- `qemu-img info`
- `qemu-img convert`
- `openstack image create --file ...` in FLEX
- waits for FLEX image to become `active`

### Optional test VM flow
- boots a FLEX VM from the imported image
- waits for the VM to become `ACTIVE`
- optionally associates a floating IP
- determines an SSH target IP

### Optional guest repair flow
When `--repair-guest` is used, it can:

- rebuild initramfs / grub where possible
- attempt a conservative `/etc/fstab` root UUID rewrite
- write a simple DHCP netplan file
- clean `cloud-init`
- remove stale persistent net rules
- install and enable `qemu-guest-agent`
- change hostname
- clean obvious stale `/etc/hosts` entries
- apply endpoint substitutions from a `old|new` map file
- restart named `systemd` services
- run basic validation commands

---

## What it does not do

This tool does **not** fully automate:

- application-aware cutover
- DB replication or DB consistency validation
- Windows guest repair
- multi-NIC static routing reconstruction
- complex storage/mount topology remediation
- LB/DNS cutover
- Redis / RabbitMQ / Kafka migration
- search cluster migration
- zero-downtime production migration

Use it as:
- a **bridge tool**
- a **rapid feasibility tester**
- a **recovery/portability helper**
- a **first stage before proper app/data migration**

---

## Requirements

The machine running the tool needs:

- `python3`
- `bash`
- `openstack` CLI
- `qemu-img`
- `ssh`
- `scp`

It also needs:

- valid **OSPC** `openrc`
- valid **FLEX** `openrc`
- SSH key for guest repair if `--repair-guest` is used
- network access to:
  - OSPC control plane
  - FLEX control plane
  - the test VM SSH endpoint if guest repair is enabled

---

## Files

- main script: `ospc2flex_image_migrator.py`
- environment template: `.env.example`

---

## Quick start

### 1. Create a working env file

```bash
cp .env.example .env
```

Edit `.env` with your values.

### 2. Load the environment

```bash
set -a
source ./.env
set +a
```

### 3. Run a dry run first

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --fix-fstab \
  --dry-run
```

### 4. Real run

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --flex-security-group "$FLEX_SECURITY_GROUP" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --ssh-user "$SSH_USER" \
  --ssh-port "$SSH_PORT" \
  --fix-fstab \
  --fix-netplan \
  --flex-net-iface "$FLEX_NET_IFACE" \
  --systemd-services "$SYSTEMD_SERVICES"
```

---

## Recommended workflow

### Option A — Build FLEX-ready image only

Use this when you want only the converted/imported image.

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME"
```

### Option B — Build image + boot FLEX test VM

Use this when you want to validate that the image boots.

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME"
```

### Option C — Full bridge flow

Use this when you want image conversion and guest repair.

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --fix-fstab \
  --fix-netplan \
  --flex-net-iface "$FLEX_NET_IFACE"
```

---

## CLI options

### Core image options

| Option | Meaning |
|---|---|
| `--ospc-openrc` | path to OSPC openrc |
| `--flex-openrc` | path to FLEX openrc |
| `--server-name` | source OSPC VM name |
| `--snapshot-name` | optional custom snapshot name |
| `--workdir` | working directory for export/convert artifacts |
| `--target-format` | target disk format, `qcow2` or `raw` |
| `--source-format` | force source format if auto-detection is wrong |
| `--flex-image-name` | imported FLEX image name |
| `--visibility` | FLEX image visibility |
| `--container-format` | FLEX Glance container format |
| `--keep-export` | keep exported intermediate image |
| `--cleanup-snapshot` | delete OSPC snapshot image after export |
| `--dry-run` | print actions without executing |

### Test VM options

| Option | Meaning |
|---|---|
| `--boot-test-vm` | boot a FLEX test VM from imported image |
| `--test-server-name` | name for test VM |
| `--flex-flavor` | FLEX flavor to use |
| `--flex-network-id` | FLEX network ID |
| `--flex-key-name` | FLEX keypair name |
| `--flex-security-group` | FLEX security group, default `default` |
| `--floating-ip` | floating IP to associate after boot |
| `--test-server-ip` | manually force SSH IP instead of auto-detect |

### Guest repair options

| Option | Meaning |
|---|---|
| `--repair-guest` | run guest repair over SSH |
| `--ssh-key-path` | SSH private key |
| `--ssh-user` | SSH username, default `ubuntu` |
| `--ssh-port` | SSH port, default `22` |
| `--jump-host` | optional SSH jump host |
| `--new-hostname` | new hostname inside guest |
| `--fix-fstab` | conservative root UUID rewrite in `/etc/fstab` |
| `--fix-netplan` | write simple netplan |
| `--flex-net-iface` | interface name for netplan, e.g. `ens3` |
| `--no-dhcp` | use `dhcp4: false` in written netplan |
| `--skip-cloud-init-clean` | skip cloud-init cleanup |
| `--skip-qemu-guest-agent` | skip qemu guest agent install |
| `--clean-hosts-file` | remove obvious stale OSPC hosts entries |
| `--app-endpoint-map-file` | file containing `old|new` substitutions |
| `--systemd-services` | comma-separated services to restart |

---

## Endpoint substitution map format

If you want the guest repair to replace OSPC endpoints in app configs, create a file like:

```text
10.50.12.10|10.60.12.10
10.50.11.10|10.60.11.10
old-api.internal|new-api.internal
old-db.internal|new-db.internal
```

Then pass:

```bash
--app-endpoint-map-file ./app_endpoint_map.txt
```

The tool will search common config roots:
- `/opt`
- `/srv`
- `/var/www`
- `/etc`

and replace matching strings in text-like files.

---

## Example commands

### 1. Dry run

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --fix-fstab \
  --dry-run
```

### 2. Full Linux bridge with DHCP netplan

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --flex-security-group "$FLEX_SECURITY_GROUP" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --ssh-user "$SSH_USER" \
  --ssh-port "$SSH_PORT" \
  --fix-fstab \
  --fix-netplan \
  --flex-net-iface "$FLEX_NET_IFACE" \
  --clean-hosts-file \
  --systemd-services "$SYSTEMD_SERVICES"
```

### 3. Full flow using floating IP

```bash
python3 ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --floating-ip "$FLOATING_IP" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH"
```

---

## Outputs

### Working directory artifacts
The working directory contains:
- exported OSPC image
- converted image
- snapshot metadata JSON
- generated guest repair shell script

### FLEX outputs
If import succeeds:
- a new FLEX image in Glance

If `--boot-test-vm` is used:
- a FLEX test VM created from that image

---

## Safety notes

### Use on DB servers with caution
This tool can move a DB VM image, but image portability is not the same as a clean application-aware DB migration. For important databases, logical dump/restore or replication is still safer.

### Netplan rewrite is intentionally simple
`--fix-netplan` writes a very basic config. It is good for:
- single-NIC test VMs
- DHCP bootstrap validation

It is not enough for:
- multiple NICs
- static routing
- bond/VLAN setups

### fstab rewrite is conservative
`--fix-fstab` only attempts to correct the root mount. Review data mounts manually.

### Endpoint substitution is broad
The endpoint map feature is useful, but you should still review:
- `.env`
- nginx/apache/haproxy configs
- systemd units
- app YAML/JSON configs

---

## Glance Image Migration Pipeline

| Step | Stage | Action | Input | Output | Method |
|------|-------|--------|-------|--------|--------|
| 1 | Stage 2 | Create OSPC Snapshot | Live OSPC VM name | Snapshot ID (private, in OSPC Glance) | `openstack server image create` |
| 2 | Stage 3 | Export snapshot to Cloud Files | Snapshot ID + RAX auth token | VHD file in `ospc2flex_exports` container | `POST /v2/tasks type=export` → poll until `success` |
| 3 | Stage 3 | Download VHD via ServiceNet | Cloud Files container + filename | `.img` file on jumphost disk | `curl` from `snet-storage101.iad3.clouddrive.com` |
| 4 | Stage 4 | Convert to qcow2 | `.img` (VHD/raw) | `.qcow2` compressed | `qemu-img convert -c -O qcow2` |
| 5 | Stage 4.5 | Offline repair (fstab + netplan) | `.qcow2` mounted via `qemu-nbd` | fstab cleaned, DHCP netplan written, cloud-init reset | `nbd mount` → `sed fstab` → write `99-ospc2flex.yaml` |
| 6 | Stage 4.6 | Per-OS repair scripts | Repaired `.qcow2` | OS-specific fixes (RHEL network, VirtIO drivers) | `ospc2flex_offline_repair.sh --os-type` |
| 7 | Stage 4.7 | Pre-upload verification | Repaired `.qcow2` | Verify network config + fstab are correct | `nbd mount` → check netplan/ifcfg + fstab |
| 8 | Stage 5 | Upload to FLEX Glance | Repaired `.qcow2` | FLEX image ID (active) | `openstack image create --file` |
| 9 | Stage 6 | Boot test VM + verify SSH | FLEX image ID + flavor + network | Running FLEX VM, SSH reachable | `openstack server create` → `wait_for_ssh` |

**Windows images (`rax_opts=4`):** Step 2 export is blocked by Rackspace licensing restrictions. Use Production Mode (`--origin-vm-ip`) which SSH-pipes `/dev/vda` directly from the origin VM, skipping Steps 1-3 entirely.

---

## Troubleshooting

### Snapshot created but export fails
Check:
- OSPC image status is `active`
- account has permission to save/export images
- enough disk space exists in `workdir`

### `qemu-img convert` fails
Check:
- detected source format
- available disk space
- image corruption
- use `--source-format` to override auto-detection

### FLEX image import fails
Check:
- FLEX quota
- target format accepted by FLEX
- visibility/container format settings
- Glance image size limits

### Test VM boots but no SSH
Check:
- security group rules
- keypair injection
- floating IP association
- NIC config inside guest
- cloud-init cleanup status
- serial console logs

### Guest repair completes but app still fails
Check:
- app endpoints still pointing to OSPC
- missing mounts
- missing runtime packages
- stale TLS paths
- `systemd` units still reference old paths/users

---

## Best use cases

This tool works best for:

- stateless web nodes
- internal utility servers
- jump hosts
- feasibility testing of image portability
- first-pass Linux VM conversion into FLEX

---

## Less ideal use cases

This tool is less ideal for:

- production DB primaries
- complex clustered services
- Windows workloads
- tightly coupled HA estates
- systems requiring exact network/storage reconstruction

---

## Suggested operator sequence

1. Run `--dry-run`
2. Run real image build/import
3. Boot FLEX test VM
4. Run guest repair
5. Validate boot, network, mounts, services
6. Validate app functionality
7. Decide whether:
   - image-lift is good enough
   - or clean rebuild + data migration is still required

---

## Summary

`ospc2flex_image_migrator.py` is the end-to-end bridge tool for:

- creating a FLEX-compatible image from an OSPC VM
- booting a FLEX test VM from that image
- applying the most common Linux guest repairs automatically

Use it to accelerate portability testing and recovery workflows, then follow with proper application-aware migration decisions.
