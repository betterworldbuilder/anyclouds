import sys

html_body = """
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Boot mode</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BIOS ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BIOS ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BIOS ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BIOS ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BIOS (MBR) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">BIOS / UEFI</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">NIC on FLEX</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-0-1-20" style="display:inline;">enp3s0</span><span id="cell-0-1-22" style="display:none;">enp3s0</span><span id="cell-0-1-24" style="display:none;">ens3</span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">eth0 (forced) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">eth0 (forced) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">eth0 (forced) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">eth0 (forced)</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Ethernet (auto)</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Network mgr</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">netplan ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-1-2-10" style="display:inline;">ifupdown</span><span id="cell-1-2-11" style="display:none;">ifupdown + source-dir</span><span id="cell-1-2-12" style="display:none;"><span style="color:#4ade80">netplan + networkd ✅</span></span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-2-2-8" style="display:inline;">NM + ifcfg ✅</span><span id="cell-2-2-9" style="display:none;"><span style="color:#4ade80">NM + ifcfg + keyfile ✅</span></span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">NM + ifcfg ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">network-scripts</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Windows Net Stack</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Root partition</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">vda1 (ext4) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">vda1 (ext4) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Auto: vda2 (xfs) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Auto: vda2 (ext4) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">vda1 (xfs/ext4)</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">C:\\ (NTFS)</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Separate /boot</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-0-4-20" style="display:inline;">NO (on root)</span><span id="cell-0-4-22" style="display:none;">NO (on root)</span><span id="cell-0-4-24" style="display:none;">YES vda16</span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">NO (on root) + EFI vda15 ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">NO (on root) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">NO (on root) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">NO (on root)</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">EFI System Part</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">NIC fix</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">netplan wildcard en*/eth* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;"><span id="cell-1-5-10" style="display:inline;">ifupdown eth0 DHCP ✅</span><span id="cell-1-5-11" style="display:none;">ifupdown eth0 DHCP ✅</span><span id="cell-1-5-12" style="display:none;"><b>netplan</b> wildcard ✅</span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;"><span id="cell-2-5-8" style="display:inline;">ifcfg-eth0 DHCP ✅</span><span id="cell-2-5-9" style="display:none;">ifcfg + <b>NM keyfile</b> ✅</span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">ifcfg-eth0 DHCP + rm ens* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">ifcfg-eth0 + rm ens*</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Inject netkvm</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Grub Update</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">CMDLINE + net.ifnames=0 ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">CMDLINE + serial + net.ifnames=0 ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BLS + grubenv + console ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">BLS + grubenv + console ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">grub.cfg re-patch / BLS</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">N/A (uses BCD)</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Boot + Disk fix</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">xvda→vda patch + sgdisk -e ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">xvda→vda patch + sgdisk -e ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">xvda→vda patch + sgdisk -e ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">xvda→vda patch + sgdisk -e ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">xvda→vda + sgdisk -e ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Start=0 storage drivers ✅</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">SELinux</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">N/A</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">N/A</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">set disabled ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">set disabled ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">enforcing → disabled ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">N/A</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">SSH user</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">ubuntu</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">root ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">almalinux</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">root ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">centos</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Administrator</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Cloud-init</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Cleared /var/lib/cloud/* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Cleared /var/lib/cloud/* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Cleared /var/lib/cloud/* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Cleared /var/lib/cloud/* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Cleared /var/lib/cloud/* ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Cloudbase-init</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Disk / VirtIO</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Modules loaded natively ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Modules loaded natively ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Modules loaded natively ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Modules loaded natively ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#fbbf24;">dracut initramfs inj (virtio_blk) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">viostor inj (Registry) ✅</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Purge Agent</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Flushes iptables/agents ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Flushes iptables/agents ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Flushes iptables/agents ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Flushes iptables/agents ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">Flushes iptables/agents ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">Disables Xen PV Start=4 ✅</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">SSH Keys</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">deleted (regen) ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">deleted & regen offline ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">deleted & regen offline ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">deleted & regen offline ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">deleted & regen offline ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">N/A</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">.autorelabel</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">N/A</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;">N/A</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">created ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">created ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">created ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;">N/A</td>
</tr>
<tr style="border-bottom:1px solid rgba(255,255,255,0.06);background:rgba(255,255,255,0.02);">
  <td style="padding:7px 10px;color:#94a3b8;font-weight:600;white-space:nowrap;">Main risk</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">low ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-1-15-10" style="display:inline;"><span style="color:#fbbf24">medium (fstab)</span></span><span id="cell-1-15-11" style="display:none;"><span style="color:#fbbf24">medium (fstab)</span></span><span id="cell-1-15-12" style="display:none;"><span style="color:#fbbf24">medium (fstab+netplan)</span></span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span id="cell-2-15-8" style="display:inline;"><span style="color:#fbbf24">medium (xfs)</span></span><span id="cell-2-15-9" style="display:none;"><span style="color:#fbbf24">medium (xfs+keyfile)</span></span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#4ade80;">low ✅</td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;"><span style="color:#f87171">high (legacy)</span></td>
  <td style="padding:7px 10px;text-align:center;font-size:0.72rem;color:#60a5fa;"><span style="color:#ef4444;font-weight:700">very high</span></td>
</tr>
"""

with open('templates/image_migrator.html', 'r', encoding='utf-8') as f:
    content = f.read()

import re

# Find the <tbody> tags
start_tag = '<tbody>'
end_tag = '</tbody>'

# Wait, search for the end of the <thead> which is nearest to the tbody we want.
start_idx = content.find(start_tag, content.find('<th style="padding:8px 10px;text-align:left;color:#818cf8;font-weight:700;min-width:110px;">Category</th>'))
if start_idx == -1:
    print("Could not find start tag")
    sys.exit(1)

end_idx = content.find(end_tag, start_idx)

new_content = content[:start_idx + len(start_tag)] + "\n" + html_body.strip() + "\n" + content[end_idx:]

with open('templates/image_migrator.html', 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Done")
