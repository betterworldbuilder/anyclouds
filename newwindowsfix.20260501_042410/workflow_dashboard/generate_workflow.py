import sys
import re

new_text = """
                            <p>Here is the precise step-by-step sequence of how the NBD-powered pipeline operates. Control is centralized dynamically on your Deployment Jumphost:</p>
                            
                            <h4 style="color: #a5b4fc; margin: 15px 0 5px; font-size: 1rem;">Phase 1: OSPC Snapshot & Export</h4>
                            <ul style="list-style-type: disc; padding-left: 25px; margin-bottom: 10px;">
                                <li><strong>Take Snapshot:</strong> The orchestration engine queries the OSPC API to securely snapshot the Origin VM.</li>
                                <li><strong>High-Speed Export:</strong> The central Jumphost pulls the snapshot directly from the OSPC Glance API into its local robust storage block at Datacenter backbone speeds.</li>
                            </ul>
                            
                            <h4 style="color: #a5b4fc; margin: 15px 0 5px; font-size: 1rem;">Phase 2: Local Processing & Offline Repair (Executing entirely on the Jumphost)</h4>
                            <ul style="list-style-type: disc; padding-left: 25px; margin-bottom: 10px;">
                                <li><strong>Local Transcode:</strong> The Jumphost leverages its own Datacenter CPU cores to transcode the block device into a KVM-optimized <code>.qcow2</code> format.</li>
                                <li><strong>Offline Guest Repair (Stage 4.5/4.6):</strong> The Jumphost mounts the <code>qcow2</code> via native NBD and surgically applies per-OS repair profiles (VirtIO driver injection, fstab fixes, grub config, cloud-init) directly to the offline disk.</li>
                                <li><strong>Direct-To-FLEX Upload:</strong> The Jumphost authenticates dynamically with FLEX, and streams the repaired <code>.qcow2</code> directly to the FLEX API.</li>
                            </ul>

                            <h4 style="color: #a5b4fc; margin: 15px 0 5px; font-size: 1rem;">Phase 3: Final Provisioning</h4>
                            <ul style="list-style-type: disc; padding-left: 25px; margin-bottom: 10px;">
                                <li><strong>Boot Target VM:</strong> With the image fully stored in FLEX, the engine instructs the FLEX API to boot up the target destination VM using the mapped Flavor and Network specs.</li>
                                <li><strong>Sanitation & Cleanup:</strong> Local states are intelligently maintained, and the initial snapshot image is deleted from OSPC to prevent your cloud bill from inflating.</li>
                            </ul>
                            
                            <div style="background: rgba(16, 185, 129, 0.1); border: 1px solid rgba(16, 185, 129, 0.3); padding: 10px; border-radius: 4px; margin-top: 15px;">
                                <span style="font-weight: 600; color: #10b981;">Architectural Advantage:</span> By centralizing execution onto a dedicated <strong>Deployment Jumphost</strong>, we guarantee unparalleled <strong>robustness, safety, and performance</strong>. The pipeline completely bypasses unpredictable origin VM network configurations, origin disk space exhaustion anomalies, and legacy OS tooling failures.
                            </div>
"""

with open('templates/image_migrator.html', 'r', encoding='utf-8') as f:
    content = f.read()

start_marker = '<p>Here is the precise step-by-step sequence of how the newly refactored pipeline operates.'
end_marker = '<!-- Per-OS Repair Table -->'

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx == -1 or end_idx == -1:
    print("Could not find markers")
    sys.exit(1)

# Ensure to delete exactly up to the end marker
new_content = content[:start_idx] + new_text.strip() + "\n\n                            " + content[end_idx:]

with open('templates/image_migrator.html', 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Done")
