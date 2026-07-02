#!/usr/bin/env python3
import os
import sys
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env, http_json


AUTH_URL = env("BANK_AUTH_URL", "http://127.0.0.1:8101")
CORE_URL = env("BANK_CORE_URL", "http://127.0.0.1:8102")
LEDGER_URL = env("BANK_LEDGER_URL", "http://127.0.0.1:8103")
CACHE_URL = env("BANK_CACHE_URL", "http://127.0.0.1:8107")


def bearer(headers):
    value = headers.get("Authorization", "")
    if value.lower().startswith("bearer "):
        return value.split(" ", 1)[1].strip()
    return ""


class GatewayHandler(JsonHandler):
    service_name = "banking-api-gateway"
    service_role = "api-gateway"

    def verify(self):
        token = bearer(self.headers)
        status, body = http_json("POST", AUTH_URL + "/verify", {"token": token})
        if status != 200 or not body.get("active"):
            return None
        return body.get("claims", {})

    def do_GET(self):
        path = self.parsed().path
        if path == "/ready":
            checks = {}
            for name, url in {
                "auth": AUTH_URL,
                "core": CORE_URL,
                "ledger": LEDGER_URL,
                "cache": CACHE_URL,
            }.items():
                status, _ = http_json("GET", url + "/health", timeout=2)
                checks[name] = status == 200
            self.send_json(200 if all(checks.values()) else 503, self.base_health() | {"checks": checks})
            return
        if path == "/api/mobile/summary":
            claims = self.verify()
            if not claims:
                self.send_json(401, {"error": "unauthorized"})
                return
            status, body = http_json("GET", CORE_URL + "/customer/overview?customer_id=" + claims["sub"])
            if status == 200:
                accounts = body.get("accounts", [])
                primary = accounts[0]["id"] if accounts else "acct-checking"
                tx_status, tx_body = http_json("GET", LEDGER_URL + "/transactions?account_id=" + primary + "&limit=5")
                body["recent_transactions"] = tx_body.get("transactions", []) if tx_status == 200 else []
            self.send_json(status, body)
            return
        if path == "/api/recipients":
            claims = self.verify()
            if not claims:
                self.send_json(401, {"error": "unauthorized"})
                return
            username = self.query().get("username", [""])[0]
            status, body = http_json("GET", CORE_URL + "/recipient?username=" + username)
            self.send_json(status, body)
            return
        if path == "/api/recipients/list":
            claims = self.verify()
            if not claims:
                self.send_json(401, {"error": "unauthorized"})
                return
            status, body = http_json("GET", CORE_URL + "/recipients")
            if status == 200:
                current_customer = claims.get("sub")
                body["recipients"] = [
                    row for row in body.get("recipients", [])
                    if row.get("customer_id") != current_customer
                ]
            self.send_json(status, body)
            return
        if path == "/api/server-metrics":
            self.send_json(200, {
                "server": self.server.server_address[0] or "0.0.0.0",
                "service": self.service_name,
                "response_time_ms": 12,
                "connections": 42,
                "lb_status": "optimal",
                "time_ms": int(time.time() * 1000),
            })
            return
        super().do_GET()

    def do_POST(self):
        path = self.parsed().path
        payload = self.read_json()
        if payload is None:
            return
        if path == "/api/login":
            status, body = http_json("POST", AUTH_URL + "/login", payload)
            self.send_json(status, body)
            return
        if path == "/api/customers":
            status, body = http_json("POST", CORE_URL + "/customers", payload)
            self.send_json(status, body)
            return
        if path == "/api/transfers":
            claims = self.verify()
            if not claims:
                self.send_json(401, {"error": "unauthorized"})
                return
            payload["customer_id"] = claims["sub"]
            status, body = http_json("POST", LEDGER_URL + "/transfers", payload)
            self.send_json(status, body)
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_API_PORT", "8100"))), GatewayHandler).serve_forever()
