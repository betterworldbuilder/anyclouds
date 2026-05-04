# CentOS 7 Repair Working Baseline

This project run validated that `ospc2flex_offline_repair.sh` is working for CentOS 7 source `104.130.29.156`.

Validated image:
- `ospc2flex-centos7-20260427-0746`
- Uploaded image ID: `e267a8cf-f590-459a-b9c4-705ec5a98b07`

Validated repair log markers:
- `Enabled network.service (legacy SysV ifup scripts — matches OSPC source setup)`
- `Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)`
- `Masked NetworkManager.service (legacy network.service owns eth0)`
- `Verified virtio_net in initramfs`
- `OFFLINE REPAIR COMPLETE`

Script baseline to keep:
- `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh`

Note:
- If ping/SSH fails after VM boot, inspect Floating IP attach and project/network scope first.
