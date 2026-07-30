"""MockBank mobile banking API — 3-tier edition (frontend / api / database).

DATABASE_URL selects the store:
  postgresql://user:pass@host:5432/db  -> PostgreSQL (production / in-cluster)
  anything else or unset               -> SQLite at /tmp/mockbank.db (local dev)

Endpoints:
  GET  /health            liveness/readiness (includes db backend + connectivity)
  GET  /api/accounts      list accounts with balances
  GET  /api/accounts/<id> single account
  POST /api/transfer      {"from": "...", "to": "...", "amount": 12.5}
  GET  /api/transactions  transfer audit log
"""
import os
import sqlite3
import threading
import time
from datetime import datetime, timezone

from flask import Flask, jsonify, request

DATABASE_URL = os.environ.get("DATABASE_URL", "")
USE_PG = DATABASE_URL.startswith(("postgresql://", "postgres://"))
SQLITE_PATH = os.environ.get("BANK_DB", "/tmp/mockbank.db")

app = Flask(__name__)
_lock = threading.Lock()

SEED_ACCOUNTS = [
    ("ACC-1001", "Dzoan Nguyen", 2500.00),
    ("ACC-1002", "Alice Tran", 1200.50),
    ("ACC-1003", "Bao Le", 640.25),
]

if USE_PG:
    import psycopg2
    import psycopg2.extras

    def db():
        conn = psycopg2.connect(DATABASE_URL)
        conn.autocommit = False
        return conn

    P = "%s"
else:
    def db():
        conn = sqlite3.connect(SQLITE_PATH)
        conn.row_factory = sqlite3.Row
        return conn

    P = "?"


def rows_to_dicts(cur):
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def init_db(retries=30, delay=2):
    """Create schema + seed. Retries so the API can start before PostgreSQL is ready."""
    last = None
    for _ in range(retries):
        try:
            conn = db()
            try:
                cur = conn.cursor()
                cur.execute(
                    "CREATE TABLE IF NOT EXISTS accounts ("
                    "id TEXT PRIMARY KEY, owner TEXT NOT NULL, balance REAL NOT NULL)"
                )
                if USE_PG:
                    cur.execute(
                        "CREATE TABLE IF NOT EXISTS transactions ("
                        "id SERIAL PRIMARY KEY, src TEXT, dst TEXT, amount REAL, at TEXT)"
                    )
                else:
                    cur.execute(
                        "CREATE TABLE IF NOT EXISTS transactions ("
                        "id INTEGER PRIMARY KEY AUTOINCREMENT, src TEXT, dst TEXT, "
                        "amount REAL, at TEXT)"
                    )
                for acc_id, owner, bal in SEED_ACCOUNTS:
                    cur.execute(
                        "INSERT INTO accounts (id, owner, balance) "
                        "SELECT " + P + "," + P + "," + P + " WHERE NOT EXISTS "
                        "(SELECT 1 FROM accounts WHERE id=" + P + ")",
                        (acc_id, owner, bal, acc_id),
                    )
                conn.commit()
                return True
            finally:
                conn.close()
        except Exception as exc:  # DB not up yet
            last = exc
            time.sleep(delay)
    raise RuntimeError("database never became ready: %s" % last)


@app.get("/health")
def health():
    backend = "postgresql" if USE_PG else "sqlite"
    try:
        conn = db()
        conn.close()
        db_ok = True
    except Exception:
        db_ok = False
    code = 200 if db_ok else 503
    return jsonify(status="ok" if db_ok else "degraded", service="bank-api",
                   version="2.0.0", db=backend, db_reachable=db_ok), code


@app.get("/api/accounts")
def accounts():
    conn = db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, owner, balance FROM accounts ORDER BY id")
        return jsonify(rows_to_dicts(cur))
    finally:
        conn.close()


@app.get("/api/accounts/<acc_id>")
def account(acc_id):
    conn = db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, owner, balance FROM accounts WHERE id=" + P, (acc_id,))
        out = rows_to_dicts(cur)
        if not out:
            return jsonify(error="account not found"), 404
        return jsonify(out[0])
    finally:
        conn.close()


@app.post("/api/transfer")
def transfer():
    body = request.get_json(silent=True) or {}
    src, dst = body.get("from"), body.get("to")
    try:
        amount = float(body.get("amount", 0))
    except (TypeError, ValueError):
        return jsonify(error="invalid amount"), 400
    if not src or not dst or amount <= 0:
        return jsonify(error="from, to and positive amount required"), 400
    with _lock:
        conn = db()
        try:
            cur = conn.cursor()
            cur.execute("SELECT balance FROM accounts WHERE id=" + P, (src,))
            s = cur.fetchall()
            cur.execute("SELECT balance FROM accounts WHERE id=" + P, (dst,))
            d = cur.fetchall()
            if not s or not d:
                return jsonify(error="unknown account"), 404
            if s[0][0] < amount:
                return jsonify(error="insufficient funds"), 409
            cur.execute("UPDATE accounts SET balance=balance-" + P + " WHERE id=" + P, (amount, src))
            cur.execute("UPDATE accounts SET balance=balance+" + P + " WHERE id=" + P, (amount, dst))
            at = datetime.now(timezone.utc).isoformat()
            cur.execute(
                "INSERT INTO transactions (src,dst,amount,at) VALUES ("
                + ",".join([P] * 4) + ")",
                (src, dst, amount, at),
            )
            conn.commit()
        finally:
            conn.close()
    return jsonify(ok=True, transferred=amount, at=at)


@app.get("/api/transactions")
def transactions():
    conn = db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, src, dst, amount, at FROM transactions ORDER BY id DESC")
        return jsonify(rows_to_dicts(cur))
    finally:
        conn.close()


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
