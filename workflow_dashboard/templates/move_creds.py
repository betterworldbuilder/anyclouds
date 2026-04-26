import re

with open('image_migrator.html', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. find the creds chunk
start_marker = "                <!-- 1. CLOUD CREDENTIALS SECTION -->"
end_marker = "                <!-- 2. DATA IMPORT & SELECTION -->"

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx == -1 or end_idx == -1:
    print("Markers not found.")
    exit(1)

# we want to grab everything from start_marker up to the hr class="divider" which is just before end_marker
chunk = content[start_idx:end_idx]

# keep exactly what we removed from the original text
new_content = content[:start_idx] + content[end_idx:]

# 2. find the injection point
target = "                    </details>\n                    \n                    <h2 class=\"section-title\""
inject_idx = new_content.find("                    </details>")

if inject_idx == -1:
    print("Target not found.")
    exit(1)

# we want to inject it right after </details>\n
inject_pt = new_content.find("\n", inject_idx) + 1

final_content = new_content[:inject_pt] + "\n" + chunk + new_content[inject_pt:]

with open('image_migrator.html', 'w', encoding='utf-8') as f:
    f.write(final_content)

print("Success")
