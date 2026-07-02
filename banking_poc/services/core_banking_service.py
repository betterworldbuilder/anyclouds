#!/usr/bin/env python3
import os
import sys
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env, http_json


DATABASE_URL = env("BANK_DATABASE_URL", "http://127.0.0.1:8106")


class CoreBankingHandler(JsonHandler):
    service_name = "banking-core"
    service_role = "core-banking"

    def do_GET(self):
        path = self.parsed().path
        if path == "/customer/overview":
            customer_id = self.query().get("customer_id", ["cust-1001"])[0]
            c_status, customer = http_json("GET", DATABASE_URL + "/internal/customer?customer_id=" + customer_id)
            a_status, accounts = http_json("GET", DATABASE_URL + "/internal/accounts?customer_id=" + customer_id)
            if c_status != 200:
                self.send_json(c_status, customer)
                return
            total = sum(account["balance_cents"] for account in accounts.get("accounts", []))
            self.send_json(200, {
                "customer": customer.get("customer"),
                "accounts": accounts.get("accounts", []),
                "total_balance_cents": total,
                "currency": "USD",
            })
            return
        if path == "/recipient":
            username = self.query().get("username", [""])[0]
            status, body = http_json("GET", DATABASE_URL + "/internal/account-lookup?username=" + username)
            self.send_json(status, body)
            return
        if path == "/recipients":
            status, body = http_json("GET", DATABASE_URL + "/internal/recipients")
            self.send_json(status, body)
            return
        super().do_GET()

    def do_POST(self):
        path = self.parsed().path
        payload = self.read_json()
        if payload is None:
            return
        if path == "/customers":
            status, body = http_json("POST", DATABASE_URL + "/internal/create-customer", payload)
            self.send_json(status, body)
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_CORE_PORT", "8102"))), CoreBankingHandler).serve_forever()
