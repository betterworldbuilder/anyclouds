#!/usr/bin/env python3
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from common import JsonHandler, env


DB_PATH = env("BANK_DB_PATH", "/opt/banking-poc/data/banking.db")
DB_ENGINE = env("BANK_DB_ENGINE", "sqlite").lower()
MYSQL_HOST = env("BANK_MYSQL_HOST", "127.0.0.1")
MYSQL_PORT = int(env("BANK_MYSQL_PORT", "3306"))
MYSQL_DATABASE = env("BANK_MYSQL_DATABASE", "bankvault_poc")
MYSQL_USER = env("BANK_MYSQL_USER", "bankpoc")
MYSQL_PASSWORD = env("BANK_MYSQL_PASSWORD", "bankpoc_poc_password")
POSTGRES_HOST = env("BANK_POSTGRES_HOST", "127.0.0.1")
POSTGRES_PORT = int(env("BANK_POSTGRES_PORT", "5432"))
POSTGRES_DATABASE = env("BANK_POSTGRES_DATABASE", "bankvault_poc")
POSTGRES_USER = env("BANK_POSTGRES_USER", "bankpoc")
POSTGRES_PASSWORD = env("BANK_POSTGRES_PASSWORD", "bankpoc_poc_password")


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def connect():
    if DB_ENGINE == "mysql":
        import pymysql

        return pymysql.connect(
            host=MYSQL_HOST,
            port=MYSQL_PORT,
            user=MYSQL_USER,
            password=MYSQL_PASSWORD,
            database=MYSQL_DATABASE,
            autocommit=True,
            cursorclass=pymysql.cursors.DictCursor,
        )
    if DB_ENGINE in ("postgres", "postgresql"):
        import psycopg2
        import psycopg2.extras

        return psycopg2.connect(
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD,
            dbname=POSTGRES_DATABASE,
            cursor_factory=psycopg2.extras.RealDictCursor,
        )
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def sql_params(sql):
    return sql.replace("?", "%s") if DB_ENGINE in ("mysql", "postgres", "postgresql") else sql


def run(conn, sql, params=()):
    if DB_ENGINE in ("mysql", "postgres", "postgresql"):
        cur = conn.cursor()
        cur.execute(sql_params(sql), params)
        return cur
    return conn.execute(sql, params)


def begin(conn):
    if DB_ENGINE == "mysql":
        conn.begin()
    elif DB_ENGINE in ("postgres", "postgresql"):
        run(conn, "BEGIN")
    else:
        conn.execute("BEGIN IMMEDIATE")


def create_schema(conn):
    if DB_ENGINE in ("mysql", "postgres", "postgresql"):
        statements = [
            """
            CREATE TABLE IF NOT EXISTS customers (
              id VARCHAR(64) PRIMARY KEY,
              name VARCHAR(255) NOT NULL,
              email VARCHAR(255) NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS users (
              username VARCHAR(128) PRIMARY KEY,
              password VARCHAR(255) NOT NULL,
              customer_id VARCHAR(64) NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS accounts (
              id VARCHAR(64) PRIMARY KEY,
              customer_id VARCHAR(64) NOT NULL,
              name VARCHAR(255) NOT NULL,
              type VARCHAR(64) NOT NULL,
              balance_cents BIGINT NOT NULL,
              currency VARCHAR(8) NOT NULL DEFAULT 'USD'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS transactions (
              id VARCHAR(96) PRIMARY KEY,
              account_id VARCHAR(64) NOT NULL,
              direction VARCHAR(16) NOT NULL,
              amount_cents BIGINT NOT NULL,
              description VARCHAR(255) NOT NULL,
              created_at VARCHAR(64) NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS audit_events (
              id VARCHAR(64) PRIMARY KEY,
              actor VARCHAR(128) NOT NULL,
              action VARCHAR(128) NOT NULL,
              detail TEXT NOT NULL,
              created_at VARCHAR(64) NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS notifications (
              id VARCHAR(64) PRIMARY KEY,
              customer_id VARCHAR(64) NOT NULL,
              channel VARCHAR(32) NOT NULL,
              message VARCHAR(255) NOT NULL,
              status VARCHAR(32) NOT NULL,
              created_at VARCHAR(64) NOT NULL
            )
            """,
        ]
    else:
        statements = [
            """
            CREATE TABLE IF NOT EXISTS customers (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              email TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS users (
              username TEXT PRIMARY KEY,
              password TEXT NOT NULL,
              customer_id TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS accounts (
              id TEXT PRIMARY KEY,
              customer_id TEXT NOT NULL,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              balance_cents INTEGER NOT NULL,
              currency TEXT NOT NULL DEFAULT 'USD'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS transactions (
              id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              direction TEXT NOT NULL,
              amount_cents INTEGER NOT NULL,
              description TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS audit_events (
              id TEXT PRIMARY KEY,
              actor TEXT NOT NULL,
              action TEXT NOT NULL,
              detail TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS notifications (
              id TEXT PRIMARY KEY,
              customer_id TEXT NOT NULL,
              channel TEXT NOT NULL,
              message TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
            """,
        ]
    for statement in statements:
        run(conn, statement)


def init_db():
    with connect() as conn:
        create_schema(conn)
        ensure_seed_customer(
            conn,
            customer_id="cust-1001",
            username="alex",
            password="demo",
            name="Alex Morgan",
            email="alex@example.com",
            checking_id="acct-checking",
            savings_id="acct-savings",
            checking_balance=2456280,
            savings_balance=1820044,
            seed_transactions=[
                ("acct-checking", "debit", 12999, "Amazon Purchase"),
                ("acct-checking", "credit", 520000, "Salary Deposit"),
                ("acct-checking", "debit", 3450, "Uber Eats"),
                ("acct-checking", "debit", 8720, "Electric Bill"),
            ],
        )
        ensure_seed_customer(
            conn,
            customer_id="cust-1002",
            username="alice",
            password="demo",
            name="Alice Chen",
            email="alice@example.com",
            checking_id="acct-alice-checking",
            savings_id="acct-alice-savings",
            checking_balance=1250000,
            savings_balance=650000,
            seed_transactions=[
                ("acct-alice-checking", "credit", 1250000, "Opening balance"),
                ("acct-alice-savings", "credit", 650000, "Savings transfer"),
            ],
        )


def ensure_seed_customer(conn, customer_id, username, password, name, email, checking_id, savings_id, checking_balance, savings_balance, seed_transactions):
    customer = run(conn, "SELECT id FROM customers WHERE id=?", (customer_id,)).fetchone()
    if not customer:
        run(conn, "INSERT INTO customers VALUES (?,?,?)", (customer_id, name, email))

    user = run(conn, "SELECT username FROM users WHERE username=?", (username,)).fetchone()
    if not user:
        run(conn, "INSERT INTO users VALUES (?,?,?)", (username, password, customer_id))

    checking = run(conn, "SELECT id FROM accounts WHERE id=?", (checking_id,)).fetchone()
    if not checking:
        run(conn, "INSERT INTO accounts VALUES (?,?,?,?,?,?)", (checking_id, customer_id, "Everyday Checking", "checking", checking_balance, "USD"))

    savings = run(conn, "SELECT id FROM accounts WHERE id=?", (savings_id,)).fetchone()
    if not savings:
        run(conn, "INSERT INTO accounts VALUES (?,?,?,?,?,?)", (savings_id, customer_id, "High Yield Savings", "savings", savings_balance, "USD"))

    for account_id, direction, amount, desc in seed_transactions:
        exists = run(conn, "SELECT id FROM transactions WHERE account_id=? AND description=?", (account_id, desc)).fetchone()
        if not exists:
            run(
                conn,
                "INSERT INTO transactions VALUES (?,?,?,?,?,?)",
                (str(uuid.uuid4()), account_id, direction, amount, desc, utc_now()),
            )


def rows_to_dicts(rows):
    return [dict(row) for row in rows]


class DatabaseHandler(JsonHandler):
    service_name = "banking-database"
    service_role = "database"

    def do_GET(self):
        path = self.parsed().path
        if path in ("/health", "/ready"):
            try:
                with connect() as conn:
                    run(conn, "SELECT 1").fetchone()
                self.send_json(200, self.base_health() | {"check": "SELECT 1", "engine": DB_ENGINE})
            except Exception as exc:
                self.send_json(503, {"status": "error", "error": str(exc)})
            return
        if path == "/internal/customer":
            customer_id = self.query().get("customer_id", ["cust-1001"])[0]
            with connect() as conn:
                row = run(conn, "SELECT * FROM customers WHERE id=?", (customer_id,)).fetchone()
            self.send_json(200 if row else 404, {"customer": dict(row) if row else None})
            return
        if path == "/internal/accounts":
            customer_id = self.query().get("customer_id", ["cust-1001"])[0]
            with connect() as conn:
                rows = run(conn, "SELECT * FROM accounts WHERE customer_id=? ORDER BY type", (customer_id,)).fetchall()
            self.send_json(200, {"accounts": rows_to_dicts(rows)})
            return
        if path == "/internal/account-lookup":
            username = self.query().get("username", [""])[0].strip()
            if not username:
                self.send_json(400, {"error": "username_required"})
                return
            with connect() as conn:
                row = run(
                    conn,
                    """
                    SELECT users.username, users.customer_id, customers.name, customers.email,
                           accounts.id AS account_id, accounts.name AS account_name, accounts.type AS account_type
                    FROM users
                    JOIN customers ON customers.id = users.customer_id
                    JOIN accounts ON accounts.customer_id = customers.id
                    WHERE users.username=? AND accounts.type='checking'
                    ORDER BY accounts.id
                    LIMIT 1
                    """,
                    (username,),
                ).fetchone()
            if not row:
                self.send_json(404, {"error": "recipient_not_found"})
                return
            self.send_json(200, {"recipient": dict(row)})
            return
        if path == "/internal/recipients":
            with connect() as conn:
                rows = run(
                    conn,
                    """
                    SELECT users.username, users.customer_id, customers.name, customers.email,
                           accounts.id AS account_id, accounts.name AS account_name, accounts.type AS account_type
                    FROM users
                    JOIN customers ON customers.id = users.customer_id
                    JOIN accounts ON accounts.customer_id = customers.id
                    WHERE accounts.type='checking'
                    ORDER BY users.username
                    """,
                ).fetchall()
            self.send_json(200, {"recipients": rows_to_dicts(rows)})
            return
        if path == "/internal/transactions":
            account_id = self.query().get("account_id", ["acct-checking"])[0]
            limit = int(self.query().get("limit", ["10"])[0])
            with connect() as conn:
                rows = run(
                    conn,
                    "SELECT * FROM transactions WHERE account_id=? ORDER BY created_at DESC LIMIT ?",
                    (account_id, limit),
                ).fetchall()
            self.send_json(200, {"transactions": rows_to_dicts(rows)})
            return
        super().do_GET()

    def do_POST(self):
        path = self.parsed().path
        payload = self.read_json()
        if payload is None:
            return
        if path == "/internal/transfer":
            from_account = payload.get("from_account_id")
            to_account = payload.get("to_account_id")
            to_username = payload.get("to_username", "").strip()
            amount_cents = int(payload.get("amount_cents", 0))
            description = payload.get("description", "Mobile transfer")
            if not from_account or (not to_account and not to_username) or amount_cents <= 0:
                self.send_json(400, {"error": "from_account_id, to_account_id or to_username, and positive amount_cents required"})
                return
            transfer_id = str(uuid.uuid4())
            created_at = utc_now()
            with connect() as conn:
                begin(conn)
                if not to_account and to_username:
                    recipient = run(
                        conn,
                        """
                        SELECT accounts.id, users.username, customers.name
                        FROM users
                        JOIN customers ON customers.id = users.customer_id
                        JOIN accounts ON accounts.customer_id = users.customer_id
                        WHERE users.username=? AND accounts.type='checking'
                        ORDER BY accounts.id
                        LIMIT 1
                        """,
                        (to_username,),
                    ).fetchone()
                    if not recipient:
                        conn.rollback()
                        self.send_json(404, {"error": "recipient_not_found"})
                        return
                    to_account = recipient["id"]
                from_row = run(conn, "SELECT balance_cents FROM accounts WHERE id=?", (from_account,)).fetchone()
                to_row = run(conn, "SELECT balance_cents FROM accounts WHERE id=?", (to_account,)).fetchone()
                if not from_row or not to_row:
                    conn.rollback()
                    self.send_json(404, {"error": "account_not_found"})
                    return
                if from_row["balance_cents"] < amount_cents:
                    conn.rollback()
                    self.send_json(409, {"error": "insufficient_funds"})
                    return
                sender = run(
                    conn,
                    """
                    SELECT users.username, customers.name
                    FROM accounts
                    JOIN users ON users.customer_id = accounts.customer_id
                    JOIN customers ON customers.id = accounts.customer_id
                    WHERE accounts.id=?
                    LIMIT 1
                    """,
                    (from_account,),
                ).fetchone()
                recipient_detail = run(
                    conn,
                    """
                    SELECT users.username, customers.name
                    FROM accounts
                    JOIN users ON users.customer_id = accounts.customer_id
                    JOIN customers ON customers.id = accounts.customer_id
                    WHERE accounts.id=?
                    LIMIT 1
                    """,
                    (to_account,),
                ).fetchone()
                sender_name = sender["name"] if sender else "Unknown sender"
                sender_username = sender["username"] if sender else "unknown"
                recipient_name = recipient_detail["name"] if recipient_detail else "Unknown recipient"
                recipient_username = recipient_detail["username"] if recipient_detail else (to_username or "unknown")
                debit_description = f"To {recipient_name} ({recipient_username}) - {to_account}"
                credit_description = f"From {sender_name} ({sender_username}) - {from_account}"
                if description and description != "Mobile transfer":
                    debit_description = f"{description} | {debit_description}"
                    credit_description = f"{description} | {credit_description}"
                run(conn, "UPDATE accounts SET balance_cents=balance_cents-? WHERE id=?", (amount_cents, from_account))
                run(conn, "UPDATE accounts SET balance_cents=balance_cents+? WHERE id=?", (amount_cents, to_account))
                run(conn, "INSERT INTO transactions VALUES (?,?,?,?,?,?)", (transfer_id + "-debit", from_account, "debit", amount_cents, debit_description, created_at))
                run(conn, "INSERT INTO transactions VALUES (?,?,?,?,?,?)", (transfer_id + "-credit", to_account, "credit", amount_cents, credit_description, created_at))
                conn.commit()
            self.send_json(201, {
                "transfer_id": transfer_id,
                "status": "posted",
                "created_at": created_at,
                "from_account_id": from_account,
                "to_account_id": to_account,
                "recipient": {"username": recipient_username, "name": recipient_name},
                "sender": {"username": sender_username, "name": sender_name},
            })
            return
        if path == "/internal/authenticate":
            username = payload.get("username", "")
            password = payload.get("password", "")
            with connect() as conn:
                row = run(
                    conn,
                    """
                    SELECT users.username, users.customer_id, customers.name, customers.email
                    FROM users
                    JOIN customers ON customers.id = users.customer_id
                    WHERE users.username=? AND users.password=?
                    """,
                    (username, password),
                ).fetchone()
            if not row:
                self.send_json(401, {"error": "invalid_credentials"})
                return
            self.send_json(200, {"user": dict(row)})
            return
        if path == "/internal/create-customer":
            name = payload.get("name", "").strip()
            email = payload.get("email", "").strip()
            username = payload.get("username", "").strip()
            password = payload.get("password", "").strip()
            opening_deposit_cents = int(payload.get("opening_deposit_cents", 250000))
            if not name or not email or not username or not password:
                self.send_json(400, {"error": "name, email, username, and password required"})
                return
            customer_id = "cust-" + uuid.uuid4().hex[:8]
            checking_id = "acct-" + uuid.uuid4().hex[:8]
            savings_id = "acct-" + uuid.uuid4().hex[:8]
            created_at = utc_now()
            try:
                with connect() as conn:
                    begin(conn)
                    existing = run(conn, "SELECT username FROM users WHERE username=?", (username,)).fetchone()
                    if existing:
                        conn.rollback()
                        self.send_json(409, {"error": "username_exists"})
                        return
                    run(conn, "INSERT INTO customers VALUES (?,?,?)", (customer_id, name, email))
                    run(conn, "INSERT INTO users VALUES (?,?,?)", (username, password, customer_id))
                    run(
                        conn,
                        "INSERT INTO accounts VALUES (?,?,?,?,?,?)",
                        (checking_id, customer_id, "Everyday Checking", "checking", opening_deposit_cents, "USD"),
                    )
                    run(
                        conn,
                        "INSERT INTO accounts VALUES (?,?,?,?,?,?)",
                        (savings_id, customer_id, "High Yield Savings", "savings", 0, "USD"),
                    )
                    run(
                        conn,
                        "INSERT INTO transactions VALUES (?,?,?,?,?,?)",
                        (str(uuid.uuid4()), checking_id, "credit", opening_deposit_cents, "Opening deposit", created_at),
                    )
                    conn.commit()
            except Exception as exc:
                self.send_json(409, {"error": "create_failed", "detail": str(exc)})
                return
            self.send_json(201, {
                "customer": {"id": customer_id, "name": name, "email": email},
                "username": username,
                "accounts": [
                    {"id": checking_id, "name": "Everyday Checking", "type": "checking", "balance_cents": opening_deposit_cents, "currency": "USD"},
                    {"id": savings_id, "name": "High Yield Savings", "type": "savings", "balance_cents": 0, "currency": "USD"},
                ],
            })
            return
        if path == "/internal/audit":
            with connect() as conn:
                run(
                    conn,
                    "INSERT INTO audit_events VALUES (?,?,?,?,?)",
                    (str(uuid.uuid4()), payload.get("actor", "system"), payload.get("action", "event"), payload.get("detail", "{}"), utc_now()),
                )
            self.send_json(201, {"status": "recorded"})
            return
        if path == "/internal/notification":
            with connect() as conn:
                run(
                    conn,
                    "INSERT INTO notifications VALUES (?,?,?,?,?,?)",
                    (str(uuid.uuid4()), payload.get("customer_id", "cust-1001"), payload.get("channel", "push"), payload.get("message", ""), "sent", utc_now()),
                )
            self.send_json(201, {"status": "sent"})
            return
        super().do_POST()


if __name__ == "__main__":
    init_db()
    port = int(env("BANK_DATABASE_PORT", "8106"))
    ThreadingHTTPServer(("", port), DatabaseHandler).serve_forever()
