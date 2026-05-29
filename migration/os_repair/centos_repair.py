from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any


VIRTIO_DRIVERS = "virtio virtio_pci virtio_blk virtio_net virtio_scsi virtio_ring"


def _result() -> dict[str, Any]:
    return {
        "detected_os": None,
        "major_version": None,
        "repair_path": None,
        "actions": [],
        "changed_files": [],
        "planned_changed_files": [],
        "warnings": [],
        "errors": [],
    }


def safe_read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def _inside_root(root: Path, path: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def backup_file(path: Path, dry_run: bool) -> Path | None:
    if not path.exists() or dry_run:
        return None
    stamp = datetime.utcnow().strftime("%Y%m%d%H%M%S")
    backup = path.with_name(f"{path.name}.ospc2flex.bak.{stamp}")
    n = 1
    while backup.exists():
        backup = path.with_name(f"{path.name}.ospc2flex.bak.{stamp}.{n}")
        n += 1
    shutil.copy2(path, backup)
    return backup


def safe_write(path: Path, content: str, dry_run: bool) -> bool:
    old = safe_read(path)
    if old == content:
        return False
    if dry_run:
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup_file(path, dry_run=False)
    path.write_text(content, encoding="utf-8")
    return True


def run_chroot(root_mount: str, cmd: list[str], dry_run: bool) -> tuple[int, str, str]:
    rendered = " ".join(cmd)
    if dry_run:
        return 0, rendered, ""
    proc = subprocess.run(
        ["chroot", root_mount, *cmd],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _record_change(res: dict[str, Any], rel: str, changed: bool, dry_run: bool) -> None:
    if not changed:
        return
    key = "planned_changed_files" if dry_run else "changed_files"
    if rel not in res[key]:
        res[key].append(rel)


def _warn_missing_chroot_mounts(root: Path, res: dict[str, Any]) -> None:
    missing = [p for p in ("/dev", "/proc", "/sys") if not (root / p.lstrip("/")).exists()]
    if missing:
        res["warnings"].append(f"chroot support paths may not be mounted: {' '.join(missing)}")


def _detect(root: Path) -> tuple[str | None, int | None, str]:
    release = safe_read(root / "etc/redhat-release").strip()
    if "centos" not in release.lower():
        return None, None, release
    m = re.search(r"release\s+(\d+)", release, re.I)
    return "centos", int(m.group(1)) if m else None, release


def _kernel_versions(root: Path) -> list[str]:
    boot = root / "boot"
    versions = []
    for p in sorted(boot.glob("vmlinuz-*")):
        versions.append(p.name.removeprefix("vmlinuz-"))
    return versions


def _centos5_initrd_path(root: Path, ver: str) -> str:
    for rel in (f"/boot/initrd-{ver}.img", f"/boot/initrd.img-{ver}", f"/boot/initramfs-{ver}.img"):
        if (root / rel.lstrip("/")).exists():
            return rel
    return f"/boot/initrd-{ver}.img"


def _root_uuid(root_mount: str) -> str:
    try:
        src = subprocess.check_output(["findmnt", "-rn", "-o", "SOURCE", "--target", root_mount], text=True).strip()
        if src:
            return subprocess.check_output(["blkid", "-s", "UUID", "-o", "value", src], text=True).strip()
    except Exception:
        return ""
    return ""


def _replace_fstab_devices(text: str) -> str:
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue
        fields = stripped.split()
        if fields and (fields[0].startswith("UUID=") or fields[0].startswith("LABEL=")):
            out.append(line)
            continue
        if len(fields) >= 3 and fields[2] in {"nfs", "nfs4", "tmpfs", "proc", "sysfs", "devpts"}:
            out.append(line)
            continue
        newline = line.replace("/dev/xvda", "/dev/vda").replace("/dev/xvdb", "/dev/vdb").replace("/dev/xvdc", "/dev/vdc")
        if len(fields) >= 2 and fields[1] == "/" and fields[0].startswith("/dev/hda"):
            newline = newline.replace("/dev/hda", "/dev/vda")
        out.append(newline)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def _repair_fstab(root: Path, res: dict[str, Any], dry_run: bool) -> None:
    path = root / "etc/fstab"
    if not path.exists():
        res["warnings"].append("/etc/fstab not found")
        return
    changed = safe_write(path, _replace_fstab_devices(safe_read(path)), dry_run)
    _record_change(res, "/etc/fstab", changed, dry_run)


def _clean_ifcfg(text: str, centos7: bool = False, force_dhcp: bool = False) -> str:
    if force_dhcp:
        return (
            "DEVICE=eth0\n"
            "TYPE=Ethernet\n"
            "BOOTPROTO=dhcp\n"
            "ONBOOT=yes\n"
            "USERCTL=no\n"
            "PEERDNS=yes\n"
            "IPV6INIT=no\n"
            "NM_CONTROLLED=no\n"
        )
    lines = []
    has_device = has_onboot = has_bootproto = False
    static = False
    for line in text.splitlines():
        if re.match(r"^\s*(HWADDR|UUID)\s*=", line, re.I):
            continue
        if re.match(r"^\s*DEVICE\s*=", line, re.I):
            lines.append("DEVICE=eth0")
            has_device = True
            continue
        if re.match(r"^\s*ONBOOT\s*=", line, re.I):
            lines.append("ONBOOT=yes")
            has_onboot = True
            continue
        if re.match(r"^\s*BOOTPROTO\s*=\s*(static|none)", line, re.I):
            static = True
        if re.match(r"^\s*(IPADDR|GATEWAY|NETMASK|PREFIX)\s*=", line, re.I):
            static = True
        if re.match(r"^\s*BOOTPROTO\s*=", line, re.I):
            has_bootproto = True
        lines.append(line)
    if not has_device:
        lines.insert(0, "DEVICE=eth0")
    if not has_onboot:
        lines.append("ONBOOT=yes")
    if not has_bootproto and not static:
        lines.append("BOOTPROTO=dhcp")
    if centos7 and not any(re.match(r"^\s*NM_CONTROLLED\s*=", l, re.I) for l in lines):
        lines.append("NM_CONTROLLED=yes")
    return "\n".join(lines).rstrip() + "\n"


def _ensure_opts(existing: str, required: list[str]) -> str:
    parts = [p for p in existing.split() if not re.match(r"(console|net\.ifnames|biosdevname)=", p)]
    for opt in required:
        if opt not in parts:
            parts.append(opt)
    return " ".join(parts).strip()


def _repair_centos5_grub(root: Path, res: dict[str, Any], dry_run: bool) -> None:
    candidates = [root / "boot/grub/grub.conf", root / "etc/grub.conf"]
    target = None
    for c in candidates:
        if c.exists() or c.is_symlink():
            resolved = c.resolve()
            if _inside_root(root, resolved):
                target = resolved
            else:
                target = c
            break
    if target is None:
        versions = _kernel_versions(root)
        if not versions:
            res["warnings"].append("CentOS 5 GRUB config not found and no /boot/vmlinuz-* kernel found")
            return
        ver = versions[-1]
        kernel = f"/vmlinuz-{ver}"
        initrd = _centos5_initrd_path(root, ver).removeprefix("/boot")
        root_arg = f"UUID={_root_uuid(str(root))}" if _root_uuid(str(root)) else "/dev/sda1"
        target = root / "boot/grub/grub.conf"
        content = (
            "default=0\n"
            "timeout=5\n"
            "serial --unit=0 --speed=115200\n"
            "terminal --timeout=5 console serial\n"
            "title CentOS 5 Flex compatibility\n"
            "    root (hd0,0)\n"
            f"    kernel {kernel} ro root={root_arg} console=tty0 console=ttyS0,115200n8 no_timer_check selinux=0\n"
            f"    initrd {initrd}\n"
        )
        changed = safe_write(target, content, dry_run)
        _record_change(res, "/boot/grub/grub.conf", changed, dry_run)
        changed = safe_write(root / "boot/grub/menu.lst", content, dry_run)
        _record_change(res, "/boot/grub/menu.lst", changed, dry_run)
        changed = safe_write(root / "boot/grub/device.map", "(hd0)\t/dev/sda\n", dry_run)
        _record_change(res, "/boot/grub/device.map", changed, dry_run)
        res["actions"].append(f"synthesized CentOS 5 legacy grub.conf root={root_arg}")
        return
    lines = []
    for line in safe_read(target).splitlines():
        if re.match(r"^\s*kernel\s+", line):
            line = re.sub(r"console=(xvc0|hvc0)", "console=ttyS0 console=tty0", line)
            for n in ("1", "2", "3"):
                line = line.replace(f"root=/dev/xvda{n}", f"root=/dev/vda{n}")
            line = line.replace("root=/dev/xvdb1", "root=/dev/vdb1").replace("root=/dev/xvdc1", "root=/dev/vdc1")
        lines.append(line)
    changed = safe_write(target, "\n".join(lines) + "\n", dry_run)
    rel = "/" + str(target.resolve().relative_to(root.resolve())) if _inside_root(root, target) else str(target)
    _record_change(res, rel, changed, dry_run)


def _repair_centos5_modprobe(root: Path, res: dict[str, Any], dry_run: bool) -> None:
    path = root / "etc/modprobe.conf"
    text = safe_read(path)
    lines = []
    eth0_done = False
    for line in text.splitlines():
        if re.match(r"^\s*alias\s+eth0\s+e1000\b", line):
            lines.append("# ospc2flex disabled for Flex KVM:")
            lines.append(f"# {line}")
            continue
        if re.match(r"^\s*alias\s+eth0\s+virtio_net\b", line):
            eth0_done = True
        lines.append(line)
    if "virtio_blk" not in "\n".join(lines):
        lines.append("alias scsi_hostadapter virtio_blk")
    if not eth0_done:
        lines.append("alias eth0 virtio_net")
    changed = safe_write(path, "\n".join(lines).rstrip() + "\n", dry_run)
    _record_change(res, "/etc/modprobe.conf", changed, dry_run)


def repair_centos5(root_mount: str, dry_run: bool = False) -> dict[str, Any]:
    root = Path(root_mount)
    res = _result()
    res.update({"detected_os": "centos", "major_version": 5, "repair_path": "centos5"})
    _warn_missing_chroot_mounts(root, res)
    _repair_centos5_grub(root, res, dry_run)
    _repair_fstab(root, res, dry_run)
    _repair_centos5_modprobe(root, res, dry_run)
    ifcfg = root / "etc/sysconfig/network-scripts/ifcfg-eth0"
    changed = safe_write(ifcfg, _clean_ifcfg(safe_read(ifcfg), force_dhcp=True), dry_run)
    _record_change(res, "/etc/sysconfig/network-scripts/ifcfg-eth0", changed, dry_run)
    for ver in _kernel_versions(root):
        initrd = _centos5_initrd_path(root, ver)
        cmd = ["mkinitrd", "--with=virtio_pci", "--with=virtio_blk", "--with=virtio_net", "--with=virtio_scsi", "-f", initrd, ver]
        rc, out, err = run_chroot(root_mount, cmd, dry_run)
        res["actions"].append("chroot " + " ".join(cmd))
        if rc != 0:
            retry = ["mkinitrd", "--with=virtio_pci", "--with=virtio_blk", "--with=virtio_net", "-f", initrd, ver]
            rc2, out2, err2 = run_chroot(root_mount, retry, dry_run)
            res["actions"].append("chroot " + " ".join(retry))
            if rc2 != 0:
                res["warnings"].append(f"mkinitrd failed for {ver}: {(err2 or err).strip()[:300]}")
    if not (root / "boot/grub/grub.conf").exists() and not (root / "etc/grub.conf").exists():
        res["warnings"].append("validation: no grub.conf found")
    if not (list((root / "boot").glob("initrd-*.img")) or list((root / "boot").glob("initrd.img-*"))):
        res["warnings"].append("validation: no /boot/initrd-*.img or initrd.img-* found")
    if "HWADDR" in safe_read(ifcfg):
        res["warnings"].append("validation: ifcfg-eth0 still contains HWADDR")
    return res


def repair_centos7(root_mount: str, dry_run: bool = False) -> dict[str, Any]:
    root = Path(root_mount)
    res = _result()
    res.update({"detected_os": "centos", "major_version": 7, "repair_path": "centos7"})
    _warn_missing_chroot_mounts(root, res)
    _repair_fstab(root, res, dry_run)
    grub = root / "etc/default/grub"
    text = safe_read(grub)
    required = ["console=ttyS0", "console=tty0", "net.ifnames=0", "biosdevname=0"]
    if 'GRUB_CMDLINE_LINUX="' in text:
        def repl(m: re.Match[str]) -> str:
            val = m.group(1).replace("console=xvc0", "").replace("console=hvc0", "")
            return f'GRUB_CMDLINE_LINUX="{_ensure_opts(val, required)}"'
        new = re.sub(r'GRUB_CMDLINE_LINUX="([^"]*)"', repl, text)
    else:
        new = text.rstrip() + f'\nGRUB_CMDLINE_LINUX="{" ".join(required)}"\n'
    changed = safe_write(grub, new, dry_run)
    _record_change(res, "/etc/default/grub", changed, dry_run)
    dracut = root / "etc/dracut.conf.d/ospc2flex-virtio.conf"
    content = "# Added by OSPC2Flex migration repair for Flex KVM boot support\nadd_drivers+=\" virtio virtio_pci virtio_blk virtio_net virtio_scsi virtio_ring \"\n"
    changed = safe_write(dracut, content, dry_run)
    _record_change(res, "/etc/dracut.conf.d/ospc2flex-virtio.conf", changed, dry_run)
    ifcfg_dir = root / "etc/sysconfig/network-scripts"
    for p in ifcfg_dir.glob("ifcfg-*"):
        if p.name == "ifcfg-lo":
            continue
        changed = safe_write(p, _clean_ifcfg(safe_read(p), centos7=True), dry_run)
        _record_change(res, "/" + str(p.relative_to(root)), changed, dry_run)
    for ver in _kernel_versions(root):
        cmd = ["dracut", "-f", "--add-drivers", VIRTIO_DRIVERS, f"/boot/initramfs-{ver}.img", ver]
        rc, out, err = run_chroot(root_mount, cmd, dry_run)
        res["actions"].append("chroot " + " ".join(cmd))
        if rc != 0:
            retry = ["dracut", "-f", "--add-drivers", "virtio_pci virtio_blk virtio_net virtio_scsi", f"/boot/initramfs-{ver}.img", ver]
            rc2, _, err2 = run_chroot(root_mount, retry, dry_run)
            res["actions"].append("chroot " + " ".join(retry))
            if rc2 != 0:
                res["warnings"].append(f"dracut failed for {ver}: {(err2 or err).strip()[:300]}")
    cmd = ["grub2-mkconfig", "-o", "/boot/grub2/grub.cfg"]
    rc, _, err = run_chroot(root_mount, cmd, dry_run)
    res["actions"].append("chroot " + " ".join(cmd))
    if rc != 0:
        res["warnings"].append(f"grub2-mkconfig failed: {err.strip()[:300]}")
    if (root / "boot/efi/EFI/centos/grub.cfg").exists():
        cmd = ["grub2-mkconfig", "-o", "/boot/efi/EFI/centos/grub.cfg"]
        run_chroot(root_mount, cmd, dry_run)
        res["actions"].append("chroot " + " ".join(cmd))
    else:
        res["warnings"].append("/boot/efi/EFI/centos/grub.cfg not found; skipped UEFI GRUB rebuild")
    return res


def repair_centos_for_flex(root_mount: str, dry_run: bool = False) -> dict[str, Any]:
    root = Path(root_mount)
    os_id, major, release = _detect(root)
    if os_id != "centos" or major not in {5, 7}:
        res = _result()
        res.update({"detected_os": os_id, "major_version": major})
        res["warnings"].append("Unsupported CentOS major version for this repair path")
        return res
    return repair_centos5(root_mount, dry_run) if major == 5 else repair_centos7(root_mount, dry_run)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Repair offline CentOS root for OSPC Xen to Flex KVM")
    sub = parser.add_subparsers(dest="cmd")
    p = sub.add_parser("repair-centos")
    p.add_argument("--root-mount", required=True)
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd != "repair-centos":
        parser.print_help()
        return 2
    res = repair_centos_for_flex(args.root_mount, args.dry_run)
    print(f"Detected: CentOS {res.get('major_version')}")
    print(f"Repair path: {res.get('repair_path')}")
    print("Changed files:")
    for f in res.get("changed_files") or res.get("planned_changed_files") or []:
        print(f"- {f}")
    print("Commands:")
    for a in res["actions"]:
        print(f"- {a}")
    print("Warnings:")
    for w in res["warnings"]:
        print(f"- {w}")
    return 1 if res["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
