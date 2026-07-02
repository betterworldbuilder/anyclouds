#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env, http_json


SECRET = env("BANK_AUTH_SECRET", "change-me-for-poc")
DATABASE_URL = env("BANK_DATABASE_URL", "http://127.0.0.1:8106")


def sign(payload):
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    body = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    sig = hmac.new(SECRET.encode("utf-8"), body.encode("ascii"), hashlib.sha256).hexdigest()
    return body + "." + sig


def verify(token):
    try:
        body, sig = token.split(".", 1)
        expected = hmac.new(SECRET.encode("utf-8"), body.encode("ascii"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return None
        raw = base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))
        payload = json.loads(raw.decode("utf-8"))
        if payload.get("exp", 0) < int(time.time()):
            return None
        return payload
    except Exception:
        return None


class AuthHandler(JsonHandler):
    service_name = "banking-auth"
    service_role = "identity"

    def do_POST(self):
        path = self.parsed().path
        payload = self.read_json()
        if payload is None:
            return
        if path == "/login":
            username = payload.get("username", "alex")
            password = payload.get("password", "demo")
            status, body = http_json("POST", DATABASE_URL + "/internal/authenticate", {
                "username": username,
                "password": password,
            })
            if status != 200:
                self.send_json(status, body)
                return
            user = body.get("user", {})
            claims = {
                "sub": user.get("customer_id", "cust-1001"),
                "name": user.get("name", username),
                "scope": "mobile:banking",
                "exp": int(time.time()) + 3600,
            }
            self.send_json(200, {"access_token": sign(claims), "token_type": "Bearer", "expires_in": 3600, "customer_id": claims["sub"]})
            return
        if path == "/verify":
            token = payload.get("token", "")
            claims = verify(token)
            self.send_json(200 if claims else 401, {"active": bool(claims), "claims": claims})
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_AUTH_PORT", "8101"))), AuthHandler).serve_forever()
