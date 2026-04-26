import sys

HTML_INJECT = """
      <!-- When to move to FLEX -->
      <div style="margin-top:48px;">
        <h2 style="color:#e8edf8; font-size:26px; font-weight:700; letter-spacing:-.01em; margin-bottom:4px;">When to move to FLEX</h2>
        <p style="color:#7889a8; font-size:13px; margin-bottom:20px; letter-spacing:.01em;">Technical and business conditions triggering a migration from Legacy Rackspace Public Cloud (OSPC) to Rackspace OpenStack Flex (FLEX).</p>
        <div style="border-radius:14px; overflow:hidden; background:rgba(10,16,36,0.72); border:1px solid rgba(120,150,220,0.18); box-shadow:0 4px 32px rgba(0,0,0,.45), 0 1px 0 rgba(255,255,255,0.05) inset; backdrop-filter:blur(16px);">
          <table class="matrix-table" style="width:100%; border-collapse:collapse; font-size:13px; table-layout:fixed; margin-top:0;">
            <colgroup>
              <col style="width:25%">
              <col style="width:40%">
              <col style="width:35%">
            </colgroup>
            <thead>
              <tr style="background:rgba(255,255,255,0.05); border-bottom:1px solid rgba(120,150,220,0.2);">
                <th style="padding:12px 16px; text-align:left; color:#6a7fa8; font-weight:600; font-size:10.5px; text-transform:uppercase; letter-spacing:.09em;">Condition / trigger</th>
                <th style="padding:12px 16px; text-align:left; color:#6a7fa8; font-weight:600; font-size:10.5px; text-transform:uppercase; letter-spacing:.09em;">Why it matters</th>
                <th style="padding:12px 16px; text-align:left; color:#6a7fa8; font-weight:600; font-size:10.5px; text-transform:uppercase; letter-spacing:.09em;">Example use case</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Need for modern, OpenStack-based infrastructure</td>
                <td>FLEX runs on current-generation OpenStack with newer APIs, better automation, and alignment with upstream cloud standards, while OSPC is based on older, legacy Rackspace Cloud architecture.</td>
                <td>A company operating a legacy PHP app on OSPC wants to automate deployments with Terraform and Kubernetes; FLEX's OpenStack API and ecosystem support tools like Magnum and Terraform more natively.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Desire for more flexible networking and segmentation</td>
                <td>FLEX offers advanced networking (VLANs, segmentation within a single account, floating IPs, etc.), whereas OSPC has more rigid networking and lacks some modern segmentation capabilities.</td>
                <td>An e-commerce platform needs separate isolated networks for PCI-compliant payment workloads and analytics; FLEX allows segmented networks under one account, which OSPC cannot easily support.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Need to import custom images or use vendor images</td>
                <td>FLEX supports custom image uploads and lets you consume upstream images from vendors like Red Hat, Canonical, Microsoft, and SUSE; OSPC is more limited in this regard.</td>
                <td>A DevOps team wants to run a Red Hat Enterprise Linux image with a pre-built tuning profile; FLEX allows direct import or use of RH images, while OSPC would require extra workarounds.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Scaling beyond legacy limits or regions</td>
                <td>FLEX provides better scalability, multi-tenant capacity, and newer hardware; OSPC is being sunsetted and does not scale as easily into newer regions or hardware generations.</td>
                <td>A SaaS provider sees traffic doubling annually and wants to add bursting in a new region; FLEX lets them scale horizontally across regions with modern hardware, while OSPC will not be expanded.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Push toward cost-efficient, license-free infrastructure</td>
                <td>FLEX is a license-free, open-source-based private cloud, which can reduce some licensing and vendor-lock-in costs compared with older OSPC models.</td>
                <td>A financial services firm wants to cut licensing fees tied to proprietary cloud layers; they migrate app workloads from OSPC to FLEX to run on fully managed, open-source infrastructure.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Requirement for advanced automation and CI/CD pipelines</td>
                <td>FLEX integrates well with modern CI/CD and orchestration tools (e.g., Kubernetes, Terraform, Ansible) because it is built on current OpenStack, while OSPC tooling is more constrained.</td>
                <td>A startup wants GitOps-driven deployments using ArgoCD; FLEX's modern API and compute flavors make it easier to automate than OSPC's legacy surfaces.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Compliance or security posture upgrade</td>
                <td>FLEX adds newer security and compliance features and supports more granular segmentation and isolation, while OSPC is being deprecated and will not receive further security enhancements.</td>
                <td>A healthcare company must comply with updated data-residency and isolation rules; they migrate from OSPC to FLEX to leverage its improved security controls and segmentation.</td>
              </tr>
              <tr>
                <td style="color:#e2e8f0; font-weight:600;">Long-term roadmap: OSPC migration program</td>
                <td>Rackspace explicitly encourages and plans migration of OSPC workloads to the Flex platform, providing migration guidance and support.</td>
                <td>A customer still running legacy WebLogic servers on OSPC works with Rackspace to migrate those VMs to FLEX over a 6-month window, aligning with their expiry roadmap.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
"""

TARGET = 'templates/combined.html'
with open(TARGET, 'r', encoding='utf-8') as f:
    text = f.read()

# Replace the closing of the compatTbody div with that + our new section
if "When to move to FLEX" not in text:
    old_str = "</tbody>\n          </table>\n        </div>\n      </div>\n    </div>\n  </div>"
    new_str = "</tbody>\n          </table>\n        </div>\n      </div>\n" + HTML_INJECT + "\n    </div>\n  </div>"
    text = text.replace(old_str, new_str)
    
    with open(TARGET, 'w', encoding='utf-8') as f:
        f.write(text)
    print("Modified combined.html successfully!")
else:
    print("Already inserted.")
