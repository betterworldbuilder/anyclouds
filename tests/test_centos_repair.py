from pathlib import Path

from migration.os_repair.centos_repair import repair_centos_for_flex


def write(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def test_centos5_detection(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.11 (Final)\n")
    res = repair_centos_for_flex(str(tmp_path), dry_run=True)
    assert res["major_version"] == 5
    assert res["repair_path"] == "centos5"


def test_centos7_detection(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS Linux release 7.9.2009 (Core)\n")
    res = repair_centos_for_flex(str(tmp_path), dry_run=True)
    assert res["major_version"] == 7
    assert res["repair_path"] == "centos7"


def test_centos5_grub_repair(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.11 (Final)\n")
    write(
        tmp_path / "boot/grub/grub.conf",
        "title CentOS\n    kernel /vmlinuz-2.6.18 ro root=/dev/xvda1 console=xvc0\n    initrd /initrd-2.6.18.img\n",
    )
    write(tmp_path / "boot/vmlinuz-2.6.18", "")
    write(tmp_path / "boot/initrd-2.6.18.img", "")
    repair_centos_for_flex(str(tmp_path))
    out = (tmp_path / "boot/grub/grub.conf").read_text()
    assert "root=/dev/vda1" in out
    assert "console=ttyS0 console=tty0" in out


def test_centos7_default_grub_repair(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS Linux release 7.9.2009 (Core)\n")
    write(tmp_path / "etc/default/grub", 'GRUB_CMDLINE_LINUX="crashkernel=auto console=xvc0"\n')
    write(tmp_path / "boot/vmlinuz-3.10.0", "")
    write(tmp_path / "boot/grub2/grub.cfg", "")
    res = repair_centos_for_flex(str(tmp_path), dry_run=True)
    assert "/etc/default/grub" in res["planned_changed_files"]
    repair_centos_for_flex(str(tmp_path))
    out = (tmp_path / "etc/default/grub").read_text()
    assert "console=ttyS0" in out
    assert "console=tty0" in out
    assert "net.ifnames=0" in out
    assert "biosdevname=0" in out


def test_fstab_repair_preserves_uuid(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.11 (Final)\n")
    write(tmp_path / "boot/grub/grub.conf", "")
    write(tmp_path / "boot/initrd-2.6.18.img", "")
    write(tmp_path / "etc/fstab", "/dev/xvda1 / ext4 defaults 1 1\n/dev/xvdb1 /data ext4 defaults 0 0\nUUID=abc /safe ext4 defaults 0 0\n")
    repair_centos_for_flex(str(tmp_path))
    out = (tmp_path / "etc/fstab").read_text()
    assert "/dev/vda1 / ext4" in out
    assert "/dev/vdb1 /data ext4" in out
    assert "UUID=abc /safe" in out


def test_centos7_dracut_dropin(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS Linux release 7.9.2009 (Core)\n")
    write(tmp_path / "etc/default/grub", "")
    write(tmp_path / "boot/vmlinuz-3.10.0", "")
    repair_centos_for_flex(str(tmp_path))
    out = (tmp_path / "etc/dracut.conf.d/ospc2flex-virtio.conf").read_text()
    assert "add_drivers+=" in out
    assert "virtio_blk" in out
    assert "virtio_net" in out
    assert "virtio_pci" in out


def test_dry_run_does_not_modify(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.11 (Final)\n")
    grub = tmp_path / "boot/grub/grub.conf"
    write(grub, "kernel /vmlinuz ro root=/dev/xvda1 console=xvc0\n")
    before = grub.read_text()
    res = repair_centos_for_flex(str(tmp_path), dry_run=True)
    assert grub.read_text() == before
    assert "/boot/grub/grub.conf" in res["planned_changed_files"]


def test_centos5_uses_existing_initrd_img_name(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.6 (Final)\n")
    write(tmp_path / "boot/grub/grub.conf", "")
    write(tmp_path / "boot/vmlinuz-2.6.34.1-rscloud", "")
    write(tmp_path / "boot/initrd.img-2.6.34.1-rscloud", "")
    res = repair_centos_for_flex(str(tmp_path), dry_run=True)
    assert any("/boot/initrd.img-2.6.34.1-rscloud" in a for a in res["actions"])


def test_centos5_synthesizes_missing_legacy_grub(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.6 (Final)\n")
    write(tmp_path / "boot/vmlinuz-2.6.34.1-rscloud", "")
    write(tmp_path / "boot/initrd.img-2.6.34.1-rscloud", "")
    res = repair_centos_for_flex(str(tmp_path))
    grub = (tmp_path / "boot/grub/grub.conf").read_text()
    assert "/vmlinuz-2.6.34.1-rscloud" in grub
    assert "/initrd.img-2.6.34.1-rscloud" in grub
    assert "root=/dev/sda1" in grub
    assert "console=ttyS0" in grub
    assert "/boot/grub/menu.lst" in res["changed_files"]


def test_centos5_forces_flex_dhcp_ifcfg(tmp_path):
    write(tmp_path / "etc/redhat-release", "CentOS release 5.6 (Final)\n")
    write(tmp_path / "boot/vmlinuz-2.6.34.1-rscloud", "")
    write(tmp_path / "boot/initrd.img-2.6.34.1-rscloud", "")
    write(
        tmp_path / "etc/sysconfig/network-scripts/ifcfg-eth0",
        "DEVICE=eth0\nBOOTPROTO=static\nIPADDR=184.106.230.116\nNETMASK=255.255.255.0\nGATEWAY=184.106.230.1\nHWADDR=aa:bb:cc:dd:ee:ff\n",
    )
    repair_centos_for_flex(str(tmp_path))
    out = (tmp_path / "etc/sysconfig/network-scripts/ifcfg-eth0").read_text()
    assert "BOOTPROTO=dhcp" in out
    assert "ONBOOT=yes" in out
    assert "IPADDR=" not in out
    assert "GATEWAY=" not in out
    assert "HWADDR=" not in out
