# Analysis: Linux Snapshot Migration

## 1. Executive Summary

Ubuntu likely fails in the snapshot migration wrapper, not in the core Ubuntu repair logic. Operator evidence says Ubuntu repair works correctly through the VM migration method. That means the primary suspects are the Linux snapshot path's source artifact handling, qcow2 resume policy, OS-type propagation, wrapper-only fallback behavior, and upload/validation gates.

The highest-risk snapshot-specific issue is that `ospc2flex_linux_snap_migrate.sh` can resume and upload a qcow2 without proving that it came from the correct snapshot and passed repair/boot validation. It can also continue after the repair helper exits nonzero, write a repair marker anyway, and report migration completion even when SSH fails.

Alma, Debian, and Rocky likely work because the real repair helper has stronger, tested branches for RHEL-family networking, BLS/grubenv, dracut/mkinitrd, and Debian network mode handling. Those branches are production-working paths and should be preserved.

RHEL/CentOS 5 is not supported by the declared helper profile. RHEL/CentOS 6 has partial support, but it needs stricter legacy grub, mkinitrd, SysV/network-script, cloud-init/nova-agent, and verification gates. RHEL/Rocky/Alma 8 has a mostly present branch, but it needs protection around LVM, BLS/grubenv, NetworkManager, and xfs/root detection.

The most important guardrail gap is upload gating: LS5 logs a repair failure as a warning, writes a repair marker anyway, and LS6 uploads. LS9 can fail SSH and still reports `MIGRATION_COMPLETE=true`. Do not change the working Alma/Debian/Rocky repair logic without isolating Ubuntu and legacy RHEL fixes behind OS-specific branches.

Read-only checks performed:
- `bash -n ospc2Flex-Image-migtool/ospc2flex_linux_snap_migrate.sh`: passed.
- `python -m py_compile ospc2Flex-Image-migtool/ospc2flex_image_migrator.py`: could not run as written because `python` is not installed in the shell environment.
- `python3 -m py_compile ospc2Flex-Image-migtool/ospc2flex_image_migrator.py`: passed using a temporary pycache outside the repo.

## 2. Pipeline Map

| Stage | File | Function / Block | What it does | Risk |
|---|---|---|---|---|
| LS0_PREFLIGHT | `ospc2flex_linux_snap_migrate.sh` | lines 686-691, `install_if_missing()` lines 124-145 | Creates run dirs and checks `qemu-img`, `qemu-nbd`, `python3`, `openstack`, `curl`. | Only checks pipeline tools, not full repair prerequisites. Real repair dependencies are left to `/tmp/ospc2flex_offline_repair.sh`. |
| LS1_LOAD_CREDENTIALS | `ospc2flex_linux_snap_migrate.sh` | lines 693-696 | Sources OSPC OpenRC and logs region/user. | Does not run `openstack token issue` in LS1, so auth may fail later inside download. |
| LS2_SELECT_SNAPSHOT | `ospc2flex_linux_snap_migrate.sh` | lines 698-704 | Uses supplied image ID or looks up image by label. | Name lookup can select wrong image if labels collide. |
| LS3_DOWNLOAD_SNAPSHOT | `ospc2flex_linux_snap_migrate.sh` | lines 707-728, helpers lines 299-621 | Resumes existing qcow2/raw or downloads via Glance, curl, Cloud Files, or Cinder fallback. | Resumes any newest `*.qcow2` under label, including previously repaired or bad qcow2. |
| LS4_NORMALIZE_QCOW2 | `ospc2flex_linux_snap_migrate.sh` | lines 731-743 | Converts raw/source artifact to compressed qcow2. | Disk-space failure is caught, but no preflight free-space estimate. |
| LS5_OFFLINE_REPAIR | `ospc2flex_linux_snap_migrate.sh` | lines 748-815 | Runs `/tmp/ospc2flex_offline_repair.sh`; otherwise minimal fallback repair. | Critical: nonzero repair is warning-only at lines 774-778; marker is written at lines 814-815. |
| LS6_UPLOAD_FLEX | `ospc2flex_linux_snap_migrate.sh` | lines 819-865 | Uploads qcow2 to FLEX Glance with virtio metadata. | Upload can happen after failed/incomplete repair. `hw_disk_bus=virtio` requires initramfs support. |
| LS6A_CREATE_FLEX_CINDER_VOLUME | `ospc2flex_linux_snap_migrate.sh` | lines 867-911 | Special volume-snapshot handoff path. | Mixed into Linux script, but only for `volsnap-*`; should not drive Glance snapshot behavior. |
| LS7_BOOT_FLEX_VM | `ospc2flex_linux_snap_migrate.sh` | lines 918-958 | Creates FLEX VM and waits ACTIVE. | ACTIVE is not proof that Linux booted or SSH/network works. |
| LS8_FLOATING_IP | `ospc2flex_linux_snap_migrate.sh` | lines 961-992 | Creates/reuses floating IP and attaches to VM port. | No hard failure if no FIP is available. |
| LS9_SSH_TEST | `ospc2flex_linux_snap_migrate.sh` | lines 995-1036 | Tries SSH as inferred user and root. | SSH failure is logged but final exits 0 with `MIGRATION_COMPLETE=true`. |
| Generated export | `ospc2flex_image_migrator.py` | `build_remote_export_script()` lines 382-414 | Generates `remote_export_<vm>_<ts>.sh` runtime script for remote export/repair/upload. | Runtime script has its own older pipeline and can hide failure context when SSH drops. |
| Repair helper | `ospc2flex_offline_repair.sh` | whole file | Mounts qcow2 via NBD and applies per-OS repair. | Actual Ubuntu/RHEL behavior lives here, not in LS5. |

## 3. OS Detection Findings

| OS Family | Current Detection | Risk | Required Detection |
|---|---|---|---|
| Ubuntu | `infer_offline_os_type()` maps Ubuntu 20/22/24 by `ID` and `VERSION_ID` lines 49-57. Repair helper maps `ubuntu*` to `OS_ID_FROM_ARG=ubuntu` lines 56-60. | Ubuntu 18.04 becomes generic `ubuntu`; helper treats all Ubuntu the same. If live SSH detection fails, repair auto-detect depends on mounted `/etc/os-release`. | Detect exact major: 18, 20, 22, 24. Record renderer, initramfs tool, grub path, EFI presence, and root spec before modifying. |
| Debian | Helper detects `/etc/os-release`, `/etc/debian_version`, and has Debian 10/11/12 branch lines 390-392 and 591-719. | Works now; risk is accidentally treating Debian 12 netplan like Ubuntu or Debian 10/11 like netplan. | Preserve Debian split: 10/11 ifupdown, 12 netplan only if tooling exists. |
| RHEL/CentOS 5 | Not declared as supported in helper header; `infer_offline_os_type()` maps old `centos` to `centos7` and old `rhel` to `rhel7` lines 77-90. | RHEL/CentOS 5 would run wrong profile. It uses grub legacy, SysV, old mkinitrd, older virtio/module naming, and may lack cloud-init. | Explicit `rhel5`/`centos5` detection from release files and kernel version; separate legacy branch. |
| RHEL/CentOS 6 | Helper has RHEL 6 logic: SysV network lines 845-867, mkinitrd fallback lines 1134-1141, grub legacy lines 1167-1257, cloud-init install lines 1496-1583. | Orchestrator currently maps RHEL/CentOS major below 7 to `rhel7`/`centos7` lines 77-90, so RHEL6 can be misrouted unless OS_TYPE is manually passed or auto-detected later. | Return `rhel6`/`centos6` from OS hint and require helper branch verification. |
| RHEL/CentOS 7 | Current helper has CentOS/RHEL 7 dracut and grub2 branch lines 1261-1320. | Working-ish path depends on successful dracut and no LVM gaps. | Preserve; add only gates and better logs. |
| RHEL/Rocky/Alma 8 | Helper maps Alma/Rocky 8 and CentOS/RHEL 8; RHEL-family branch handles ifcfg, BLS, grubenv, dracut lines 735-1164 and 1326-1333. | Mostly present, but LVM roots are skipped by root scan and BLS/EFI layouts vary. | Keep OS 8 as distinct branch with BLS/grubenv, xfs/ext4, optional LVM activation, NetworkManager check. |
| Rocky/Alma 9 | Helper has explicit `alma9`/`rocky9`, writes ifcfg plus NM keyfile for OS major >= 9 lines 779-819. | Working path. Risk is broad RHEL-family changes breaking it. | Preserve current branch; add tests before touching. |

## 4. Ubuntu Failure Analysis

| Area | Current Behavior | Likely Failure | Evidence in Code | Recommended Future Fix |
|---|---|---|---|---|
| Snapshot artifact path | Snapshot migration downloads/resumes from Glance/Cinder/local artifacts, then converts to qcow2. VM migration streams the live VM disk and uses its own generated remote export stages. | Ubuntu snapshot failures can come from a bad or mismatched artifact, stale resumed qcow2, partial conversion, or wrong source image, while VM migration succeeds because it streams the actual root disk. | Snapshot LS3/LS4 lines 707-743. VM migration stream/convert path in `ospc2flex_image_migrator.py` lines 543-690. | Treat artifact provenance as the first suspect. Log source image ID, artifact path, qemu-img virtual size, partitions, OS release, and root UUID before repair. |
| Resume behavior | Snapshot path resumes the newest `*.qcow2` under the label and skips download. | A previously bad Ubuntu qcow2 can be reused indefinitely, making repair look guilty when the real problem is stale artifact reuse. | `find_resume_qcow2()` lines 626-629 and LS3 resume lines 708-714. | Resume only raw source or validated pre-repair qcow2; never resume repaired/failed qcow2 without matching image ID and validation metadata. |
| Wrapper repair gate | Snapshot LS5 calls the same repair helper but treats nonzero exit as warning and still writes marker. | Core repair may fail or not run against the intended artifact, yet LS6 still uploads. | `ospc2flex_linux_snap_migrate.sh` lines 766-778 and 814-815. | Make snapshot wrapper fail on repair failure; write marker only after validation. |
| OS-type propagation | VM migration probes origin OS over SSH and passes a repair profile. Snapshot path depends on UI/metadata or mounted auto-detect. | Snapshot Ubuntu can be launched with missing/wrong `--os-type`, making helper auto-detect or generic paths differ from VM migration. | VM OS probe lines 2085-2148 in `ospc2flex_image_migrator.py`; snapshot OS_TYPE use lines 46, 88, 641. | Snapshot path should mount/read `/etc/os-release` before repair and log the exact selected repair profile. |
| netplan | Deletes all netplan files and writes wildcard `en*`/`eth*` DHCP with renderer `networkd`. | Ubuntu 18/20/22/24 may use cloud-init generated netplan, NetworkManager, or strict permissions. A single renderer may be wrong for all. | `ospc2flex_offline_repair.sh` lines 516-544. | Split Ubuntu by version and existing renderer; write one clean config only after recording current state. |
| fstab | All OS fstab cleanup rewrites `/dev/xvda` to `/dev/vda`, preserves UUID/LABEL/PARTUUID, comments non-root `/dev/*`. | If root is LVM or fstab has unusual root/boot layout, root detection and preservation can be wrong. | lines 1394-1426. | Add pre/post fstab report and fail if root/boot cannot be verified. |
| initramfs | Ubuntu VM migration works, so initramfs repair is not the leading suspect. Snapshot wrapper still lacks a validation check proving the repaired snapshot image has the expected boot state. | Snapshot may upload an unrepaired or stale qcow2, causing a boot issue that looks like initramfs. | Snapshot LS5/LS6 lines 748-865. | First add snapshot provenance/repair validation. Only change Ubuntu initramfs logic if logs prove it differs from the working VM migration output. |
| grub | Ubuntu branch rewrites `/etc/default/grub` and patches grub.cfg text. | Direct patch may miss EFI path or separate `/boot`; no `update-grub` run, so future kernel updates may revert. | lines 551-576. | Resolve `/boot` and `/boot/efi`; update default grub and run `update-grub` when safe; verify no `xvda` remains. |
| cloud-init | All OS writes OpenStack datasource then disables cloud-init networking globally. | On Ubuntu, disabling cloud-init network while relying on netplan may be okay, but could conflict with images expecting cloud-init to render network or SSH keys. | lines 1598-1641. | For Ubuntu, decide explicitly: either cloud-init network disabled plus static netplan, or cloud-init OpenStack network enabled; log the decision. |
| stale network state | Ubuntu deletes netplan and udev persistent rules, clears DHCP leases later. | May not clear systemd-networkd state or NetworkManager connections if Ubuntu image used NM. | lines 546-549, 1651-1655. | Clear `/run` is irrelevant offline; clear persistent networkd leases and NM connections if present. |
| root device naming | Global grub/fstab rewrite handles `/dev/xvda` -> `/dev/vda`. | Does not handle root by LVM, `/dev/disk/by-path`, or old `xvd*` data disk references inside initramfs config. | lines 1433-1493. | Verify kernel cmdline root target resolves inside mounted image. |
| qemu-nbd/chroot cleanup | Repair helper has cleanup trap, but Linux script passes `--nbd-dev` after overwriting parsed value. | Parallel jobs can collide on `/dev/nbd0`, and failed fallback repair can leave mounts if ERR trap fires mid-minimal branch. | `ospc2flex_linux_snap_migrate.sh` parses `--nbd-dev` line 52 then resets `NBD_DEV=/dev/nbd0` line 81. | Preserve requested NBD device; add per-run NBD lock and cleanup verification. |

Ubuntu version notes:
- Ubuntu 18.04: netplan exists but early images may still carry ifupdown remnants; initramfs update is still required.
- Ubuntu 20.04: netplan/cloud-init interaction is common; stale 50-cloud-init YAML can break DHCP.
- Ubuntu 22.04: same netplan risk, plus stricter cloud-init datasource behavior.
- Ubuntu 24.04: netplan permissions and systemd-networkd behavior are stricter; one-size Ubuntu handling is riskier.

## 5. Working Paths to Preserve

| OS | Current Working Logic | File/Function | Do Not Change |
|---|---|---|---|
| Debian 10/11 | ifupdown mode with `/etc/network/interfaces` and `source-directory`. | `ospc2flex_offline_repair.sh` lines 591-719. | Do not replace with Ubuntu netplan logic. |
| Debian 12 | netplan only when netplan tooling exists. | `ospc2flex_offline_repair.sh` lines 599-634. | Keep Debian 12 separate from Ubuntu. |
| Alma 8 | ifcfg-eth0, no NM keyfile, RHEL-family BLS/grubenv/dracut path. | lines 735-819, 932-1164. | Do not force keyfile-only networking. |
| Alma 9 | ifcfg-eth0 plus NM keyfile dual mode. | lines 779-819. | Preserve dual mode. |
| Rocky 8/9 | RHEL-family ifcfg/NM, BLS/grubenv and dracut handling. | lines 735-1164. | Do not change BLS/grubenv updates without tests. |
| CentOS/RHEL 7 | legacy network.service, dracut, grub2-mkconfig path. | lines 872-914, 1261-1320. | Do not apply RHEL8 BLS-only logic to 7. |

## 6. RHEL/CentOS Legacy Gap Analysis

| OS | Missing Support | Why It Matters | Required Future Branch |
|---|---|---|---|
| RHEL/CentOS 5 | No explicit supported token or branch. No confirmed mkinitrd/grub legacy v0.97 path for EL5. | EL5 uses older SysV, old module/initrd behavior, no systemd, likely no cloud-init, and old sshd/udev. | Add `rhel5`/`centos5`: mkinitrd with virtio, grub.conf/device.map, eth0 ifcfg, remove persistent-net, no systemd assumptions. |
| RHEL/CentOS 6 | Partial branch exists but orchestrator OS hint maps old releases to 7. Cloud-init install from vault is risky. | RHEL6 needs mkinitrd fallback, GRUB Legacy, SysV network, old OpenSSH keys, and may not have cloud-init. | Add exact `rhel6`/`centos6` hinting and make repair verification strict. |
| RHEL/CentOS 8 | RHEL-family branch exists. Needs LVM/EFI/BLS validation. | EL8 boots through BLS/grubenv and usually xfs/LVM; wrong root detection or BLS miss breaks boot. | Keep RHEL8 branch separate from 7/9; verify BLS, grubenv, dracut, NetworkManager. |

## 7. Root Partition / LVM Analysis

The current root partition detection is partly fixed-path and partly heuristic.

In `ospc2flex_offline_repair.sh`, Ubuntu and Debian default to `${NBD_DEV}p1`; RHEL-family starts empty and scans for the largest Linux filesystem. The scan explicitly skips `LVM2_member` partitions, so LVM roots are not supported unless the mounted partition itself is not LVM or `--root-part` is supplied. Evidence: lines 249-278.

The helper can resolve `/boot` and `/boot/efi` from fstab for RHEL-family work, using `fstab_spec_for_mountpoint()` and `resolve_part_by_fstab_spec()` lines 90-135 and 932-938. That is useful but does not equal full root discovery.

Filesystem support:
- ext filesystems are handled through `fsck`/`e2fsck`.
- xfs is handled through `xfs_repair -L` and mounted with `nouuid`.
- ext3 should work as an ext filesystem, but EL5-specific initrd/grub handling is not declared.
- LVM is the main unsupported/root-risk gap.

Failure cases to fix later:
- Root inside LVM VG/LV.
- Separate `/boot` not mounted before Ubuntu grub patching.
- EFI grub path not patched for Ubuntu/Debian.
- Root by `/dev/disk/by-*` paths not normalized.
- Incorrectly treating first partition as root for Ubuntu/Debian when images have separate boot/root layouts.

## 8. Chroot / Cleanup Analysis

The repair helper has a cleanup trap that unmounts `/boot/efi`, `/boot`, `/proc`, `/sys`, `/dev`, root, runs fsck/xfs repair, disconnects NBD, and removes the temporary mount directory. Evidence: `cleanup()` lines 193-217.

For RHEL-family initramfs rebuild, it bind-mounts `/proc`, `/sys`, `/dev`, and `/run` before chrooting, then unmounts them. Evidence: lines 1106-1160.

For RHEL/CentOS 6 cloud-init install, it bind-mounts `/proc`, `/sys`, `/dev`, `/run`, copies resolver config, runs yum in chroot, restores resolver config, and unmounts. Evidence: lines 1512-1567.

Risks:
- The Linux snapshot wrapper overwrites a caller-supplied `--nbd-dev` by setting `NBD_DEV=/dev/nbd0` after argument parsing. Evidence: parse line 52, reset line 81.
- The minimal fallback repair inside `ospc2flex_linux_snap_migrate.sh` has weaker cleanup than the helper and should not be relied on for Ubuntu/RHEL.
- The helper can mount root read-only on dirty filesystems; later write operations may fail under `set -e`, which cleanup should handle, but LS5 wrapper can still continue if the helper exits nonzero.

## 9. Upload Gate Analysis

Failed repair images can currently upload.

Evidence:
- LS5 captures `REPAIR_EXIT`, logs success on 0, but logs only a warning on nonzero and continues. See `ospc2flex_linux_snap_migrate.sh` lines 766-778.
- LS5 writes `${QCOW}.linux_repaired` regardless of repair success. See lines 814-815.
- LS6 uploads the qcow2 immediately after LS5. See lines 819-865.
- LS9 logs SSH failure but still prints `MIGRATION_COMPLETE=true` and exits 0. See lines 1013-1036.

Checks missing before FLEX Glance upload:
- Strict repair exit gate.
- No residual `xvda`/bad root references in boot configs.
- Initramfs contains required virtio disk module for the selected bus.
- Root partition can be mounted and `/sbin/init` exists.
- OS-specific network config exists and does not conflict.
- qemu-img check after repair.
- Optional dry boot indicator is not available because local KVM is not part of this pipeline, so console/SSH post-boot must be strict.

## 10. Generated Script Analysis

`ospc2flex_image_migrator.py` generates runtime scripts through `build_remote_export_script()` lines 382-414. These are written under `image_migrator_work/remote_export_<vm_name>_<ts>.sh` at lines 2181-2188, copied to the processing host, and launched over SSH at lines 2201-2213.

Variables passed into the generated script include snapshot name/id, OSPC and FLEX OpenRC paths, target format, visibility, retries, origin VM connection info, offline repair method, and `repair_os_type`.

OS detection before generation:
- The orchestrator probes the origin VM over SSH for `/etc/os-release`, trying users `ubuntu`, `centos`, `rocky`, `almalinux`, `debian`, `ec2-user`, and `root`. See lines 2085-2137.
- It calls `infer_offline_os_type()` at lines 2140-2148.
- `infer_offline_os_type()` maps Ubuntu/Debian/Rocky/Alma/RHEL/CentOS based on `ID`, `VERSION_ID`, and name patterns. See `ospc2flex_repair_os_hint.py` lines 16-127.

Failure context risks:
- If SSH OS detection fails, the repair helper must auto-detect from the mounted filesystem.
- Generated runtime logs are text logs, not a structured stage result.
- SSH retry assumes the remote script resumes from checkpoints, but checkpoints are not equivalent to validated repair state.
- Ubuntu-specific repair failure may be hidden because LS5 in the Linux snapshot path treats repair failure as warning-only.

Volume snapshot separation:
- `ospc2flex_volsnap_migrate.sh` is a direct Cinder-volume path and does not use FLEX Glance/qcow2; it should stay separate.
- `ospc2flex_volsnap_migrate_flexglance.sh` creates a qcow2 from a Cinder volume snapshot, then execs into `ospc2flex_linux_snap_migrate.sh` for LS4-LS9. It shares LS4-LS9 risks but is not the root cause of Ubuntu Glance snapshot failures by itself.

## 11. Proposed Fix Plan, But Do Not Implement

Phase 1: Add logging and detection report.
- Record OS ID/version, root partition, fstype, boot partition, EFI partition, fstab root spec, grub files found, initramfs files found, and selected network mode.
- Write a per-run `linux_repair_detection.json`.
- Make LS5 include the repair exit code in structured result output.

Phase 2: Add Ubuntu repair branch.
- Split Ubuntu 18/20/22/24.
- Preserve the current netplan cleanup approach, but decide renderer based on installed tools and existing service.
- Add `/etc/initramfs-tools/modules` virtio entries.
- Bind mount `/proc`, `/sys`, `/dev`, `/run`; run `update-initramfs -u -k all`.
- Resolve `/boot` and `/boot/efi` before grub updates.
- Verify no residual `xvda` and verify initramfs contains virtio disk modules.

Phase 3: Add RHEL5/RHEL6/RHEL8 branches.
- Add exact OS hint mapping for `rhel5`, `centos5`, `rhel6`, `centos6`.
- Keep RHEL7 and RHEL8 logic separate.
- Add EL5 mkinitrd/grub legacy/SysV branch.
- Make EL6 mkinitrd/grub legacy/cloud-init/nova-agent branch strict but not destructive.
- Keep RHEL8/Rocky8/Alma8 BLS/grubenv/dracut path intact.

Phase 4: Add verification gate.
- LS5 must fail if repair helper exits nonzero.
- Write repair marker only after successful repair and validation.
- LS6 must refuse upload if validation failed.
- LS9 should fail migration if SSH is required and does not pass.

Phase 5: Add tests.
- Shell syntax tests.
- OS hint unit tests.
- Fixture tests for Ubuntu 18/20/22/24 netplan/grub/initramfs decisions.
- Fixture tests for Debian 10/11/12, Alma/Rocky 8/9, CentOS/RHEL 5/6/7/8.
- Resume tests to ensure raw/qcow2 resume does not skip required repair incorrectly.

## 12. Risk Matrix

| Risk | Severity | Affected OS | Current Evidence | Future Mitigation |
|---|---|---|---|---|
| Repair failure uploads anyway | Critical | All, especially Ubuntu | LS5 warning-only lines 774-778; marker lines 814-815 | Fail LS5 on nonzero repair; marker only after validation. |
| Ubuntu initramfs not rebuilt | Critical | Ubuntu 18/20/22/24 | Ubuntu branch lines 516-580; no `update-initramfs` found | Add Ubuntu initramfs rebuild and verification. |
| Bad qcow2 resume | High | All | `find_resume_qcow2()` lines 626-629; LS3 resumes newest qcow2 lines 708-714 | Resume raw/qcow2 only with validated metadata and repair version. |
| NBD device override lost | High | Parallel jobs | Parse `--nbd-dev` line 52, reset line 81 | Move default before parsing or preserve parsed value. |
| LVM root unsupported | High | RHEL/Rocky/Alma, some Ubuntu | Root scan skips `LVM2_member` line 273 | Add vgscan/vgchange and LV root detection. |
| LS9 reports complete after SSH fail | High | All | lines 1013-1036 | Make SSH/console validation a real gate. |
| RHEL/CentOS 5 misdetected | High | EL5 | No token; old RHEL/CentOS map to 7 in `ospc2flex_repair_os_hint.py` | Add EL5 detection and branch. |
| RHEL/CentOS 6 misrouted | Medium-High | EL6 | Old RHEL/CentOS map to 7 lines 77-90 | Return EL6 tokens and test helper branch. |
| Ubuntu cloud-init/network conflict | Medium | Ubuntu | Disables cloud-init network for all OS lines 1637-1641 | Make Ubuntu network ownership explicit per version. |
| Volume path mixed into Linux script | Medium | VOLSNAP only | LS6A lines 867-911 | Keep separate; only touch shared LS4-LS9 gates. |

## 13. Files That Would Need Changes Later

| File | Why It May Need Change | Priority | Safe to Touch? |
|---|---|---|---|
| `ospc2Flex-Image-migtool/ospc2flex_linux_snap_migrate.sh` | LS5 upload gate, repair marker, resume policy, NBD override, validation gate. | P0 | Yes, but keep Alma/Debian/Rocky logic delegated. |
| `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh` | Ubuntu initramfs/grub/netplan branch, EL5/EL6 exact branches, LVM support. | P0 | Yes, with OS-specific isolated changes. |
| `ospc2Flex-Image-migtool/ospc2flex_repair_os_hint.py` | Add `rhel5`, `centos5`, `rhel6`, `centos6`; improve Ubuntu 18 mapping. | P1 | Yes, small and testable. |
| `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py` | Improve generated-script logging and OS profile propagation. | P1 | Yes, avoid changing working upload flow. |
| `ospc2Flex-Image-migtool/ospc2flex_volsnap_migrate.sh` | No direct change for Ubuntu Glance failures. | P3 | Avoid unless volume path has its own issue. |
| `ospc2Flex-Image-migtool/ospc2flex_volsnap_migrate_flexglance.sh` | Shares LS4-LS9 after handoff; only affected by shared gates. | P3 | Avoid direct behavior changes unless testing VOLSNAP. |

## 14. No-Change Confirmation

No files were modified. This was analysis only.
