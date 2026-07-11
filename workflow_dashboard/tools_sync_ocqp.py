"""Regenerate the ocqp (Real Production OpenCenter Deployment) panel body from the
ocqs (Quickstart) body so both panels stay at feature parity.
CSS class names (class="ocqs-*", .ocqs- selectors) are shared and preserved;
ids, function names, state vars and localStorage keys get the ocqp prefix."""
import re, sys

P = r"\\wsl.localhost\Ubuntu\home\dzoan\OSPC2FLEX\osflex-deployer-fullmig-5.0.0420current\workflow_dashboard\templates\partials\_panel_s2_opencenter.html"
lines = open(P, encoding="utf-8").read().split(chr(10))

def find(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    raise SystemExit("marker not found")

s_open = find(lambda l: 'id="ocqs-inline-body"' in l)
s_end = find(lambda l: "<!-- end inline body -->" in l, s_open)
p_open = find(lambda l: 'id="ocqp-inline-body"' in l, s_end)
p_end = find(lambda l: "<!-- end inline body -->" in l, p_open)

body = chr(10).join(lines[s_open + 1:s_end])

# protect shared CSS class usages, then swap prefix, then restore
body = re.sub(r'class="([^"]*)"', lambda m: 'class="' + m.group(1).replace("ocqs-", "\x01") + '"', body)
body = body.replace(".ocqs-", ".\x01")          # CSS/querySelector class selectors
body = body.replace("ocqs", "ocqp")              # ids, #id selectors, fn names, storage keys
body = re.sub(r"\b_qs\b", "_qp", body)
body = body.replace("\x01", "ocqs-")

out = lines[:p_open + 1] + body.split(chr(10)) + lines[p_end:]
open(P, "w", encoding="utf-8").write(chr(10).join(out))
print("ocqp body regenerated from ocqs: %d -> %d lines" % (p_end - p_open - 1, s_end - s_open - 1))
