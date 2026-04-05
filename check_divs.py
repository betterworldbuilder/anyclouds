import sys
from html.parser import HTMLParser

class P(HTMLParser):
    depth = 0
    s4_depth = -1
    s5_depth = -1

    def handle_starttag(self, tag, attrs):
        if tag == "div":
            self.depth += 1
            d = dict(attrs)
            if d.get("id") == "panel-s4":
                self.s4_depth = self.depth
            if d.get("id") == "panel-s5":
                self.s5_depth = self.depth
                print(f"panel-s5 found at depth {self.depth}. Is it inside panel-s4 ({self.s4_depth})? {self.depth > self.s4_depth}")

    def handle_endtag(self, tag):
        if tag == "div":
            if self.depth == self.s4_depth:
                self.s4_depth = -1 # exited panel-s4
            self.depth -= 1

p = P()
with open("workflow_dashboard/templates/combined.html", encoding="utf-8") as f:
    p.feed(f.read())
