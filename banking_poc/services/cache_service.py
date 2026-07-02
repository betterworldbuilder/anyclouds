#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env


CACHE = {}
CACHE_BACKEND = env("BANK_CACHE_BACKEND", "memory").lower()
REDIS_HOST = env("BANK_REDIS_HOST", "127.0.0.1")
REDIS_PORT = env("BANK_REDIS_PORT", "6379")


def redis_command(*args):
    command = ["redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT, "--raw", *map(str, args)]
    result = subprocess.run(command, check=True, text=True, capture_output=True, timeout=3)
    return result.stdout.rstrip("\n")


class CacheHandler(JsonHandler):
    service_name = "banking-cache"
    service_role = "cache"

    def _cleanup(self):
        now = time.time()
        expired = [key for key, item in CACHE.items() if item["expires_at"] and item["expires_at"] < now]
        for key in expired:
            CACHE.pop(key, None)

    def do_GET(self):
        path = self.parsed().path
        if path in ("/health", "/ready"):
            if CACHE_BACKEND == "redis":
                try:
                    ping = redis_command("PING")
                    keys = int(redis_command("DBSIZE"))
                    self.send_json(200 if ping == "PONG" else 503, self.base_health() | {"check": ping, "backend": "redis", "keys": keys})
                except Exception as exc:
                    self.send_json(503, {"status": "error", "backend": "redis", "error": str(exc)})
                return
            self._cleanup()
            self.send_json(200, self.base_health() | {"check": "PING", "backend": "memory", "keys": len(CACHE)})
            return
        if path == "/cache/get":
            if CACHE_BACKEND == "redis":
                key = self.query().get("key", [""])[0]
                try:
                    value = redis_command("GET", key)
                    self.send_json(200 if value else 404, {"key": key, "value": value or None})
                except Exception as exc:
                    self.send_json(503, {"error": str(exc)})
                return
            self._cleanup()
            key = self.query().get("key", [""])[0]
            item = CACHE.get(key)
            self.send_json(200 if item else 404, {"key": key, "value": item["value"] if item else None})
            return
        super().do_GET()

    def do_POST(self):
        if self.parsed().path == "/cache/set":
            payload = self.read_json()
            if payload is None:
                return
            key = payload.get("key")
            ttl = int(payload.get("ttl_seconds", 300))
            if not key:
                self.send_json(400, {"error": "key_required"})
                return
            if CACHE_BACKEND == "redis":
                try:
                    if ttl:
                        redis_command("SETEX", key, ttl, payload.get("value", ""))
                    else:
                        redis_command("SET", key, payload.get("value", ""))
                    self.send_json(201, {"status": "stored", "key": key, "backend": "redis"})
                except Exception as exc:
                    self.send_json(503, {"error": str(exc)})
                return
            CACHE[key] = {"value": payload.get("value"), "expires_at": time.time() + ttl if ttl else None}
            self.send_json(201, {"status": "stored", "key": key})
            return
        super().do_POST()


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(env("BANK_CACHE_PORT", "8107"))), CacheHandler).serve_forever()
