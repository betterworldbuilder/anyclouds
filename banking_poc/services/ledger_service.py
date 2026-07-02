#!/usr/bin/env python3
import os
import sys
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env, http_json


DATABASE_URL = env("BANK_DATABASE_URL", "http://127.0.0.1:8106")
AUDIT_URL = env("BANK_AUDIT_URL", "http://127.0.0.1:8104")
NOTIFICATION_URL = env("BANK_NOTIFICATION_URL", "http://127.0.0.1:8105")


class LedgerHandler(JsonHandler):
    service_name = "banking-ledger"
    service_role = "ledger"

    def do_GET(self):
        if self.parsed().path == "/transactions":
            account_id = self.query().get("account_id", ["acct-checking"])[0]
            limit = self.query().get("limit", ["10"])[0]
            status, body = http_json("GET", DATABASE_URL + "/internal/transactions?account_id=" + account_id + "&limit=" + limit)
            self.send_json(status, body)
            return
        super().do_GET()

    def do_POST(self):
        if self.parsed().path == "/transfers":
            payload = self.read_json()
            if payload is None:
                return
            status, body = http_json("POST", DATABASE_URL + "/internal/transfer", payload)
            if status < 300:
                http_json("POST", AUDIT_URL + "/events", {
                    "actor": payload.get("customer_id", "cust-1001"),
                    "action": "transfer.posted",
                    "detail": str(body),
                })
                http_json("POST", NOTIFICATION_URL + "/notify", {
                    "customer_id": payload.get("customer_id", "cust-1001"),
                    "channel": "push",
                    "message": "Transfer posted: " + str(body.get("transfer_id")),
                })
            self.send_json(status, body)
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_LEDGER_PORT", "8103"))), LedgerHandler).serve_forever()
