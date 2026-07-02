#!/usr/bin/env python3
import os
import sys
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env, http_json


DATABASE_URL = env("BANK_DATABASE_URL", "http://127.0.0.1:8106")


class AuditHandler(JsonHandler):
    service_name = "banking-audit"
    service_role = "audit"

    def do_POST(self):
        if self.parsed().path == "/events":
            payload = self.read_json()
            if payload is None:
                return
            status, body = http_json("POST", DATABASE_URL + "/internal/audit", payload)
            self.send_json(status, body)
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_AUDIT_PORT", "8104"))), AuditHandler).serve_forever()
