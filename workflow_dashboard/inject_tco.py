import sys

HTML_INJECT = """
          </p>
          <p style="color:#ddd; line-height:1.6; font-size:15px; margin-top:15px; margin-bottom:15px;">
            Switching from Legacy Rackspace Public Cloud (OSPC) to Rackspace OpenStack Flex typically offers lower licensing and long-term TCO but can involve similar or slightly higher per-VM compute costs, depending on sizing and region.
          </p>
          <p style="color:#ddd; line-height:1.6; font-size:15px; margin-bottom:15px;">
            Below is a practical breakdown of costs and savings drivers and how they usually balance out.
          </p>
          
          <div style="background:rgba(0,0,0,0.3); border-radius:8px; overflow:hidden; border:1px solid rgba(243,156,18,0.3); margin-top:10px;">
            <table style="width:100%; border-collapse:collapse; font-size:13px; text-align:left;">
              <thead style="background:rgba(243,156,18,0.15); border-bottom:1px solid rgba(243,156,18,0.25);">
                <tr>
                  <th style="padding:12px 16px; color:#fcd34d; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; font-size:11px;">Area</th>
                  <th style="padding:12px 16px; color:#fcd34d; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; font-size:11px;">How Flex reduces cost</th>
                  <th style="padding:12px 16px; color:#fcd34d; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; font-size:11px;">Typical saving angle</th>
                </tr>
              </thead>
              <tbody style="color:#cbd5e1;">
                <tr style="border-bottom:1px solid rgba(255,255,255,0.06); transition:background 0.2s;">
                  <td style="padding:12px 16px; font-weight:600; color:#fff; vertical-align:top;">Licensing and vendor lock-in</td>
                  <td style="padding:12px 16px; vertical-align:top;">Flex is license-free, open-source OpenStack, unlike proprietary hyperscalers and some legacy-layer products.</td>
                  <td style="padding:12px 16px; vertical-align:top;">Lower TCO: no vendor-specific license fees, plus easier migration off-platform if needed.</td>
                </tr>
                <tr style="border-bottom:1px solid rgba(255,255,255,0.06); transition:background 0.2s;">
                  <td style="padding:12px 16px; font-weight:600; color:#fff; vertical-align:top;">Bandwidth and egress</td>
                  <td style="padding:12px 16px; vertical-align:top;">Flex advertises no egress-style overage fees (included bandwidth within its pricing model), unlike some hyperscalers that charge per-GB egress.</td>
                  <td style="padding:12px 16px; vertical-align:top;">High-traffic or hybrid apps gain: predictable monthly bills vs. "surprise" bandwidth spikes.</td>
                </tr>
                <tr style="transition:background 0.2s;">
                  <td style="padding:12px 16px; font-weight:600; color:#fff; vertical-align:top;">Infrastructure efficiency</td>
                  <td style="padding:12px 16px; vertical-align:top;">Newer, modern hardware and flexible scaling mean you can right-size VMs and avoid over-provisioning older OSPC-era instances.</td>
                  <td style="padding:12px 16px; vertical-align:top;">Moderate savings (roughly 10–30% TCO) if you optimize instance sizes and turn off unused VMs.</td>
                </tr>
              </tbody>
            </table>
          </div>
"""

TARGET = 'templates/combined.html'
with open(TARGET, 'r', encoding='utf-8') as f:
    text = f.read()

target_str = """making it ideal for optimizing spend while maintaining reliability.
          </p>"""

if "Switching from Legacy Rackspace Public" not in text:
    text = text.replace(target_str, """making it ideal for optimizing spend while maintaining reliability.""" + HTML_INJECT)
    
    with open(TARGET, 'w', encoding='utf-8') as f:
        f.write(text)
    print("Modified combined.html successfully!")
else:
    print("Already inserted.")
