import sys

HTML_INJECT = """
      <!-- How to Migrate Guide -->
      <div style="margin-top:48px;">
        <h2 style="color:#e8edf8; font-size:26px; font-weight:700; letter-spacing:-.01em; margin-bottom:4px;">How to migrate workloads from OSPC to Rackspace OpenStack Flex</h2>
        <p style="color:#7889a8; font-size:13px; margin-bottom:20px; letter-spacing:.01em;">
          Migrating workloads from Legacy Rackspace Public Cloud (OSPC) to Rackspace OpenStack Flex is currently done at the VM-and-data level, not via a one-button “lift-and-shift” tool. Below is a practical step-by-step outline you can follow.
        </p>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">1. Assess and plan the migration</h3>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li><strong>Inventory all OSPC VMs:</strong> roles, OS, disk sizes, dependencies, and network requirements (ports, IPs, DNS).</li>
            <li><strong>Define sequence:</strong> which services go first (e.g., non-production, then web tiers, then databases).</li>
            <li><strong>Decide on FLEX topology:</strong> project, regions, networks, and security-group design that match your OSPC layout.</li>
          </ul>
        </div>
        
        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">2. Prepare the FLEX target environment</h3>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li>Create a Rackspace OpenStack Flex project and ensure you have the right quota and region.</li>
            <li>Build networks and subnets in FLEX to mirror your OSPC-era segmentation (e.g., app, DB, DMZ).</li>
            <li>Provision equivalent or larger flavors (VM types) and set up SSH keys and security groups so ports (22, 80, 443, DB ports, etc.) are open.</li>
          </ul>
        </div>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">3. Choose a migration method</h3>
          <p style="color:#ddd; line-height:1.6; font-size:14px; margin-bottom:10px;">There is no direct in-place convert of an OSPC server into a FLEX server; you must move data between VMs. Common options:</p>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li><strong>rsync over SSH:</strong> Best for incremental file-based transfers (web apps, configs, logs). Example: <code style="background:#111;padding:2px 4px;border-radius:3px;">rsync -avz -e ssh /opt/app/ user@flex-vm:/opt/app/</code></li>
            <li><strong>SCP / SFTP:</strong> Simple for small datasets but less efficient for large volumes.</li>
            <li><strong>Compressed archives (tar, zip):</strong> Useful when you want to package entire app directories and transfer them in one go.</li>
            <li><strong>Database dumps:</strong> Dump databases on OSPC (<code style="background:#111;padding:2px 4px;border-radius:3px;">mysqldump</code>, <code style="background:#111;padding:2px 4px;border-radius:3px;">pg_dump</code>), transfer the dump file, then restore into a fresh DB VM on FLEX.</li>
            <li><strong>Cloud Backup:</strong> Install the Rackspace Cloud Backup agent on a FLEX VM using your OSPC credentials; backups taken of OSPC servers can be restored to that FLEX VM. Create a backup policy on OSPC, then restore to the FLEX server.</li>
          </ul>
        </div>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">4. Rebuild the software stack on FLEX</h3>
          <p style="color:#ddd; line-height:1.6; font-size:14px; margin-bottom:5px;">For each migrated workload:</p>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li>Install the same OS version (or newer, if supported) and package manager sources.</li>
            <li>Recreate users, groups, and directory structure.</li>
            <li>Reinstall dependencies: web server, app server, middleware, monitoring agents, etc.</li>
            <li>Adjust paths and configs to match FLEX’s networking (floating IPs, DNS, and any new mount points).</li>
          </ul>
        </div>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">5. Test and validate</h3>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li>Start services and check logs for errors (e.g., <code style="background:#111;padding:2px 4px;border-radius:3px;">systemctl status</code>, <code style="background:#111;padding:2px 4px;border-radius:3px;">journalctl</code>, app logs).</li>
            <li>Run functional tests: HTTP endpoints, API calls, DB queries, and business workflows.</li>
            <li>Verify performance and latency compared with OSPC; adjust flavors or networking if needed.</li>
          </ul>
        </div>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #3498db; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#3498db; margin-top:0; margin-bottom:10px; font-size:18px;">6. Cutover and clean-up</h3>
          <ul style="color:#ddd; line-height:1.6; font-size:14px; margin:0; padding-left:20px;">
            <li>Update DNS or load-balancer entries to point to the new FLEX IPs.</li>
            <li>Optionally keep the old OSPC VM powered off but intact for a rollback window.</li>
            <li>After a successful stabilization period, decommission the OSPC VM and stop any OSPC-specific billing.</li>
          </ul>
        </div>

        <div style="background:rgba(0,0,0,0.25); border-left:4px solid #e056fd; padding:25px; border-radius:8px; box-shadow:0 4px 15px rgba(0,0,0,0.2); margin-bottom:15px;">
          <h3 style="color:#e056fd; margin-top:0; margin-bottom:10px; font-size:18px;">7. Optional: Use Rackspace-assisted migration</h3>
          <p style="color:#ddd; line-height:1.6; font-size:14px; margin:0;">Rackspace recommends engaging your account/support team for large-scale or critical-path migrations, as they can help with planning, backup strategy, and troubleshooting.</p>
        </div>
      </div>
"""

TARGET = 'templates/combined.html'
with open(TARGET, 'r', encoding='utf-8') as f:
    text = f.read()

# I will append this directly before the very last closing tags of the panel-s_why div
if "How to migrate workloads from OSPC" not in text:
    # Look for the exact end of the 'When to move to FLEX' section we injected previously.
    old_str = "</tbody>\n          </table>\n        </div>\n      </div>\n    </div>\n  </div>"
    
    # We replace it by inserting HTML_INJECT before the closing tags
    new_str = "</tbody>\n          </table>\n        </div>\n      </div>\n" + HTML_INJECT + "\n    </div>\n  </div>"
    text = text.replace(old_str, new_str)
    
    with open(TARGET, 'w', encoding='utf-8') as f:
        f.write(text)
    print("Modified combined.html successfully!")
else:
    print("Already inserted.")
