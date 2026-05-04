import sys

TARGET = 'app.py'
with open(TARGET, 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('yield f": keepalive {empty_polls}\\\\n\\\\n"', 'yield f": keepalive {empty_polls}\\n\\n"')

with open(TARGET, 'w', encoding='utf-8') as f:
    f.write(text)
print('Fixed backslashes.')
