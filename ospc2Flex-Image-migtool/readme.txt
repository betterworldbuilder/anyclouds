1. Why? What this tool does

You wanted a tool that makes an OSPC VM image directly FLEX-ready in one flow instead of doing the snapshot/export/convert/import steps manually every time.

I created a CLI tool that automates:

OSPC server snapshot creation
waiting for image readiness
image export from OSPC
qemu-img inspection
conversion into FLEX target format, usually qcow2
optional direct import into FLEX Glance

It is based on the conversion path and image-compatibility adjustments from your matrix.

2. How to use it
📄 File

ospc2flex_image_builder.py

Dry run
python3 ospc2flex_image_builder.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --server-name web-01 \
  --workdir ./image_bridge_work \
  --target-format qcow2 \
  --dry-run
Real run: build FLEX-ready image locally
python3 ospc2flex_image_builder.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --server-name web-01 \
  --workdir ./image_bridge_work \
  --target-format qcow2
Real run: build and import into FLEX
python3 ospc2flex_image_builder.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --flex-openrc ~/flex-openrc.sh \
  --server-name web-01 \
  --workdir ./image_bridge_work \
  --target-format qcow2 \
  --import-to-flex \
  --flex-image-name web-01-flex-ready
What it needs installed
openstack
qemu-img
bash
valid OSPC and FLEX openrc files
3. What file and exact code changes with precise locations
📄 File:

ospc2flex_image_builder.py

📍 Location:

New standalone CLI tool

🧩 Action:

Created full script and syntax-checked it

Validation note

I ran a Python syntax check successfully.

What it automates exactly
openstack server image create
wait for OSPC image to become active
openstack image save
qemu-img info
qemu-img convert
optional openstack image create --file on FLEX
Important limit

This tool makes the image FLEX-ready at the image format/import level.
It does not repair the guest OS inside the VM after boot. That is the next layer:

initramfs
fstab
NIC config
cloud-init
app endpoint changes



Done.

📄 File

ospc2flex_image_migrator.py

What it does

This merged tool now handles:

OSPC snapshot creation
image export
qemu-img inspect + convert
FLEX image import
optional FLEX test VM boot
optional SSH guest repair inside the booted VM
Guest repair it can automate
initramfs / grub regeneration
conservative fstab UUID rewrite
optional simple netplan rewrite
cloud-init cleanup
qemu guest agent install
optional hostname change
optional stale /etc/hosts cleanup
optional app endpoint substitutions from a map file
optional service restarts
Example usage
Build FLEX-ready image only
python3 ospc2flex_image_migrator.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --flex-openrc ~/flex-openrc.sh \
  --server-name web-01
Build image, import, boot test VM
python3 ospc2flex_image_migrator.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --flex-openrc ~/flex-openrc.sh \
  --server-name web-01 \
  --boot-test-vm \
  --flex-flavor gp.7.1.2 \
  --flex-network-id YOUR_FLEX_NETWORK_ID \
  --flex-key-name YOUR_FLEX_KEYPAIR
Full flow with guest repair
python3 ospc2flex_image_migrator.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --flex-openrc ~/flex-openrc.sh \
  --server-name web-01 \
  --boot-test-vm \
  --flex-flavor gp.7.1.2 \
  --flex-network-id YOUR_FLEX_NETWORK_ID \
  --flex-key-name YOUR_FLEX_KEYPAIR \
  --repair-guest \
  --ssh-key-path ~/.ssh/id_rsa \
  --fix-fstab \
  --fix-netplan \
  --flex-net-iface ens3 \
  --systemd-services nginx,myapp.service
With endpoint replacements

Create a map file:

10.50.12.10|10.60.12.10
10.50.11.10|10.60.11.10
old-api.internal|new-api.internal

Then run:

python3 ospc2flex_image_migrator.py \
  --ospc-openrc ~/ospc-openrc.sh \
  --flex-openrc ~/flex-openrc.sh \
  --server-name web-01 \
  --boot-test-vm \
  --flex-flavor gp.7.1.2 \
  --flex-network-id YOUR_FLEX_NETWORK_ID \
  --flex-key-name YOUR_FLEX_KEYPAIR \
  --repair-guest \
  --ssh-key-path ~/.ssh/id_rsa \
  --app-endpoint-map-file ./app_endpoint_map.txt
Validation note

I syntax-checked it successfully.

The next best addition is a README + env.example so the operator can run this safely without guessing flags. 



