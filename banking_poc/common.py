#!/usr/bin/env python3
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse


VERSION = "1.0.0"


def env(name, default):
    return os.environ.get(name, default)


def now_ms():
    return int(time.time() * 1000)


def json_dumps(payload):
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")


def http_json(method, url, payload=None, headers=None, timeout=5):
    body = None
    request_headers = {"Content-Type": "application/json"}
    if headers:
        request_headers.update(headers)
    if payload is not None:
        body = json_dumps(payload)
    req = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            return resp.status, json.loads(data.decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        data = exc.read()
        try:
            parsed = json.loads(data.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            parsed = {"error": data.decode("utf-8", errors="replace")}
        return exc.code, parsed
    except Exception as exc:
        return 503, {"error": str(exc), "upstream": url}


class JsonHandler(BaseHTTPRequestHandler):
    service_name = "service"
    service_role = "component"

    def log_message(self, fmt, *args):
        print("%s - - [%s] %s" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def parsed(self):
        return urlparse(self.path)

    def query(self):
        return parse_qs(self.parsed().query)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid_json"})
            return None

    def send_json(self, status, payload, extra_headers=None):
        body = json_dumps(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Request-Id")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("X-Service-Name", self.service_name)
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_json(204, {})

    def base_health(self):
        return {
            "service": self.service_name,
            "role": self.service_role,
            "status": "ok",
            "version": VERSION,
            "time_ms": now_ms(),
        }

    def do_GET(self):
        path = self.parsed().path
        if path in ("/health", "/ready"):
            self.send_json(200, self.base_health())
            return
        if path == "/version":
            self.send_json(200, {"service": self.service_name, "version": VERSION})
            return
        self.send_json(404, {"error": "not_found", "path": path})

