import openstack

print("Connecting to OpenStack...")

conn = openstack.connect(
    auth_url="https://keystone.api.dfw3.rackspacecloud.com/v3/",
    project_id="49a2c18a567c402ef560bb0f11821b61",
    username="dzng.8294",
    password="0b6f44aad11f4c6fbaeaa159151dd316",
    user_domain_name="rackspace_cloud_domain",
    project_domain_name="rackspace_cloud_domain",
    region_name="DFW3"
)

instances_to_ip = [
  "ospc2flex-dbian12-20260425-2221",
  "ospc2flex-alma8-20260425-2221",
  "ospc2flex-rocky8-20260425-2221",
  "ospc2flex-rocky9-20260425-2221",
  "ospc2flex-u20-20260425-2221",
  "ospc2flex-Alma9-20260425-2221",
  "ospc2flex-centos7-20260425-2221",
  "ospc2flex-dbian10new-20260425-2221",
  "ospc2flex-debian11new-20260425-2221"
]

public_net = conn.network.find_network("PUBLICNET")

if not public_net:
    print("Error: Could not find PUBLICNET")
    exit(1)

# Fetch unassigned floating IPs
print("Fetching existing floating IPs...")
all_fips = list(conn.network.ips())
free_fips = [fip for fip in all_fips if fip.port_id is None]
print(f"Found {len(free_fips)} unassociated floating IPs out of {len(all_fips)} total.")

for vm_name in instances_to_ip:
    server = conn.compute.find_server(vm_name)
    if not server:
        print(f"Warning: Server {vm_name} not found! Skipping.")
        continue
        
    print(f"\nChecking IP for {vm_name}...")
    # Check if already has a public IP attached
    already_has = False
    for net, addrs in server.addresses.items():
        for addr in addrs:
            if addr.get('OS-EXT-IPS:type') == 'floating':
                print(f"Server already has floating IP {addr['addr']}")
                already_has = True
                
    if already_has:
        continue
    
    fip = None
    if len(free_fips) > 0:
        fip = free_fips.pop(0)
        print(f"Re-using unassigned floating IP: {fip.floating_ip_address}")
    else:
        print(f"No free IPs available, attempting to allocate new one from PUBLICNET for {vm_name}...")
        try:
            fip = conn.network.create_ip(floating_network_id=public_net.id)
            print(f"Successfully allocated {fip.floating_ip_address}.")
        except Exception as e:
            print(f"Failed to allocate new floating IP: {e}")
            continue
    
    if fip:
        fip_addr = fip.floating_ip_address
        print(f"Assigning {fip_addr} to {vm_name} via Neutron Port...")
        try:
            ports = list(conn.network.ports(device_id=server.id))
            if not ports:
                print(f"Failed to find network port for {vm_name}")
                continue
            
            conn.network.update_ip(fip, port_id=ports[0].id)
            print(f"Assigned {fip_addr} to {vm_name} successfully!")
        except Exception as e:
            print(f"Failed to assign {fip_addr} to {vm_name}: {e}")

print("\nAll IP assignments completed.")
