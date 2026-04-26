sudo bash -lc 'OUT="bootcfg_$(hostname)_$(date +%Y%m%d_%H%M%S).txt";
{
echo "=== HOST ==="; hostname; date;
echo;
echo "=== OS ==="; cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null;
echo;
echo "=== KERNEL ==="; uname -a;
echo;
echo "=== DISK ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT 2>/dev/null || df -h;
echo;
echo "=== FSTAB ==="; grep -vE "^\s*#|^\s*$" /etc/fstab 2>/dev/null;
echo;
echo "=== GRUB LEGACY CONFIG RHEL6 ==="; cat /boot/grub/grub.conf 2>/dev/null || echo "No /boot/grub/grub.conf";
echo;
echo "=== GRUB2 CONFIG RHEL7+ ==="; grep -E "menuentry|linux16|linuxefi|initrd16|initrdefi|root=" /boot/grub2/grub.cfg 2>/dev/null || echo "No /boot/grub2/grub.cfg";
echo;
echo "=== INITRAMFS FILES ==="; ls -lh /boot/initramfs-* /boot/initrd-* 2>/dev/null;
echo;
echo "=== INITRAMFS TOOLS ==="; which mkinitrd 2>/dev/null || true; which dracut 2>/dev/null || true;
echo;
echo "=== KERNEL MODULES VIRTIO/XEN ==="; lsmod | egrep "virtio|xen|xvd|vd" || true;
echo;
echo "=== NETWORK ==="; ip addr 2>/dev/null || ifconfig -a 2>/dev/null;
echo;
echo "=== ROUTES ==="; ip route 2>/dev/null || route -n 2>/dev/null;
} | tee "$OUT";
echo;
echo "Saved to: $OUT"'
