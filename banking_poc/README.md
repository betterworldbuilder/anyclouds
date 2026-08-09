# BankSys Mobile Banking POC

BankSys is a small multi-component banking business-system POC for migration demos. It uses your existing `banking_app.html` mobile UI and deploys realistic backend components across one or more Ubuntu 24.04 OSPC servers.

The installer can deploy every component, start systemd services, check health, and run a real business test:

1. Create a new banking customer and accounts.
2. Log in from the mobile API.
3. Retrieve account and balance information.
4. Transfer money between accounts or to another registered user.
5. Retrieve updated account information.

This is a POC scaffold for migration testing, dependency mapping, and cutover validation. It is not production banking software.

## Architecture

```text
Mobile Web App :8080
        |
        v
API Gateway :8100
   |       |        |
   v       v        v
Auth    Core     Ledger
:8101   :8102    :8103
   |       |        |
   +-------+--------+------> Database Service :8106 -> MySQL or PostgreSQL local engine
                    |
                    +------> Audit :8104
                    |
                    +------> Notification :8105

API Gateway also checks Cache Service :8107 -> Redis local engine
```

Other app components do not connect directly to MySQL, PostgreSQL, or Redis. They use the Database Service API on `8106` and Cache Service API on `8107`.

## Component Plan

| Component | Port | Purpose | OSPC Flavor | OS | Installed Software / Engine | Health / Test Path |
|---|---:|---|---|---|---|---|
| Frontend Web / Mobile App | `8080` | Serves your `banking_app.html` mobile banking UI through nginx | `m1.small` or 1-2 vCPU / 2 GB RAM | Ubuntu 24.04 | nginx, static HTML, PIGGYBANK API adapter | `/` |
| API Gateway / Mobile API | `8100` | Main entry point for login, create account, account info, transfers, metrics | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 API service, systemd unit | `/health`, `/ready`, `/version` |
| Auth / Identity Service | `8101` | Handles login and token verification | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 auth service, token signing, systemd unit | `/health` |
| Core Banking Backend | `8102` | Owns customer profile, account creation, account overview, balances | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 core banking service, systemd unit | `/health` |
| Ledger / Transfer Service | `8103` | Handles money transfer and transaction history | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 ledger service, systemd unit | `/health` |
| Audit / Compliance Log | `8104` | Records business events such as posted transfers | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 audit service, systemd unit | `/health` |
| Notification Service | `8105` | Simulates mobile push/SMS/email notification after transfers | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 notification service, systemd unit | `/health` |
| Database Service | `8106` | Stores customers, users, accounts, transactions, audit, notifications | `m1.large` or 4 vCPU / 8 GB RAM, 50+ GB volume | Ubuntu 24.04 | MySQL Server + PyMySQL, or PostgreSQL + psycopg2, plus Python 3 database API service | `/health`, `/ready`, `SELECT 1` |
| Cache Service | `8107` | Cache API backed by Redis for readiness/session-style POC checks | `m1.small` or 1-2 vCPU / 2 GB RAM | Ubuntu 24.04 | Redis Server, redis-tools, Python 3 cache API service | `/health`, `/ready`, Redis `PING` |

## Recommended VM Layouts

For the simplest lab, use one Ubuntu 24.04 VM and enter the same IP for every component prompt.

For a cleaner migration demo, use five VMs:

| VM | Components |
|---|---|
| VM 1 | Frontend Web / Mobile App |
| VM 2 | API Gateway / Mobile API |
| VM 3 | Auth / Identity + Core Banking Backend |
| VM 4 | Ledger / Transfer + Audit / Compliance + Notification |
| VM 5 | Database Service + Cache Service |

For the most explicit dependency demo, use one VM per component.

## Network Requirements

Allow SSH from your WSL Ubuntu/client host:

```text
TCP 22
```

Allow these app ports between POC servers:

```text
TCP 8080  Frontend Web / Mobile App
TCP 8100  API Gateway / Mobile API
TCP 8101  Auth / Identity
TCP 8102  Core Banking Backend
TCP 8103  Ledger / Transfer
TCP 8104  Audit / Compliance
TCP 8105  Notification
TCP 8106  Database Service API
TCP 8107  Cache Service API
```

Keep engine ports local unless you explicitly need direct debugging:

```text
TCP 3306  MySQL local to Database server
TCP 5432  PostgreSQL local to Database server
TCP 6379  Redis local to Cache server
```

## What The Installer Installs

| Server | Installer Action |
|---|---|
| Frontend | Installs nginx, copies the bundled feature-complete mobile UI, installs `bankvault_api_adapter.js`, enables Register/Login/Transfer, shows external Dev View live data movement, and proxies `/api/` to API Gateway |
| API Gateway | Installs Python 3 runtime and `banking-api-gateway.service` |
| Auth | Installs Python 3 runtime and `banking-auth.service` |
| Core Banking | Installs Python 3 runtime and `banking-core-banking.service` |
| Ledger | Installs Python 3 runtime and `banking-ledger.service` |
| Audit | Installs Python 3 runtime and `banking-audit.service` |
| Notification | Installs Python 3 runtime and `banking-notification.service` |
| Database | Installs either MySQL + PyMySQL or PostgreSQL + psycopg2, creates DB/user, starts `banking-database.service` |
| Cache | Installs Redis + redis-tools, starts `banking-cache.service` |

## Prerequisites

Run the installer from WSL Ubuntu or a Linux machine that can SSH to the OSPC servers.

Local client requirements:

```bash
ssh
scp
curl
python3
tar
```

Target server requirements:

```text
Ubuntu 24.04 LTS
SSH reachable
sudo-capable user, usually ubuntu
APT access to Ubuntu package repositories
```

Default SSH key:

```bash
~/.ssh/id_rsa
```

The installer detects that key automatically if it exists. You can also enter another key path when prompted.

## Step 1: Create Source Infra VMs

Create Ubuntu 24.04 OSPC servers for your chosen layout.

Record the IPs for:

```text
Frontend
API Gateway
Auth
Core Banking
Ledger
Audit
Notification
Database
Cache
```

If multiple components share a VM, use the same IP for those prompts.

## Step 2: Confirm SSH Access

From WSL Ubuntu:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@SERVER-IP
```

Repeat for each distinct VM. The installer uses SSH/SCP to copy the code and run the component installers.

## Step 3: Place The Frontend HTML

The installer can use your existing file:

```text
/mnt/c/Users/dzoa7866/OneDrive - Rackspace Inc/Desktop/RACKSPACE/OSPC2FLEX/banking_app.html
```

The default frontend is the bundled `banking_app_live.html`, which includes the PIGGYBANK mobile controls and external Dev View. You can still provide a custom HTML file when prompted; the installer will add the PIGGYBANK adapter and config scripts automatically.

## Step 4: Run The Interactive Installer

From this folder:

```bash
cd /home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/banking_poc
chmod +x BankSys-install.sh
./BankSys-install.sh
```

At launch, the installer displays this README so the operator can review the plan before entering IPs.

The installer remembers the last values you entered in:

```text
.banksys-install.env
```

On the next run, those values appear as the defaults for each prompt. Press Enter to reuse a saved value.

## Step 5: Answer Installer Prompts

Typical answers:

```text
SSH user for component servers [ubuntu]: ubuntu
SSH port [22]: 22
SSH private key path, blank for default agent/key [/home/dzoan/.ssh/id_rsa]: /home/dzoan/.ssh/id_rsa
Shared auth secret for Auth and API Gateway [...]: press Enter or provide your own
Database engine on Database server: mysql or postgresql [mysql]: mysql
Database name on Database server [bankvault_poc]: bankvault_poc
Database app user on Database server [bankpoc]: bankpoc
Database app password on Database server [...]: press Enter or provide your own
```

For the database engine, choose one:

```text
mysql
postgresql
```

Then enter each component IP. Use the same IP for components that share a server.

## Step 6: What Happens During Install

The installer performs these actions:

1. Packages the full `banking_poc` folder.
2. Copies the package to each target server.
3. Installs the Database component first.
4. Installs Cache.
5. Installs Auth, Audit, Notification.
6. Installs Core Banking.
7. Installs Ledger.
8. Installs API Gateway.
9. Installs Frontend nginx.
10. Checks every component health endpoint.
11. Creates two reusable mock mobile banking accounts.
12. Offers to run an end-to-end business transaction test.

The mock accounts created during install are:

```text
username: alex
password: demo
customer: Alex Morgan

username: alice
password: demo
customer: Alice Chen
```

The frontend is configured to auto-load Alex through `bankvault_config.js`. Use the quick switch buttons in the web/mobile app to jump between Alex and Alice. The page also includes an external Dev View showing the active data route and live event log for each Register, Login, Refresh, Recipient Lookup, and Transfer action.

The PIGGYBANK mobile UI installed by default includes:

```text
Top login/register card
Logout button in the app header
Send button that opens the transfer card on demand
Recipient dropdown populated from all registered users
Receive mockup
Utilities payment mockup for rent, electricity, mobile, internet, and car
Analytics mockup with income and spending charts
Cards mockup with add-card option
Invest mockup with S&P 500 watchlist
Settings mockup with theme and notification controls
External Dev View showing active data movement across components
```

You can override the mock credentials before running the installer:

```bash
export BANKSYS_MOCK_USERNAME="demo.customer"
export BANKSYS_MOCK_PASSWORD="<choose-a-password>"
export BANKSYS_MOCK_EMAIL="demo.customer@example.com"
export BANKSYS_MOCK_NAME="Demo Customer"
./BankSys-install.sh
```

## Step 7: End-To-End Business Test

When prompted:

```text
Run end-to-end business test through the web/mobile app now? [Y/n]:
```

Choose `Y`.

The test calls the frontend URL and verifies:

```text
Create account    -> /api/customers
Log in            -> /api/login
Get account info  -> /api/mobile/summary
Transfer money    -> /api/transfers
Get updated info  -> /api/mobile/summary
```

Successful output ends with:

```text
Business system test passed.
Mobile web app: http://FRONTEND-IP:8080/
```

## Manual API Checks

Replace IPs with your deployed addresses.

Check gateway readiness:

```bash
curl http://API-GATEWAY-IP:8100/ready
```

Create a new customer. Pick a password first — these examples read it from
`$POC_PASSWORD` rather than hardcoding one:

```bash
export POC_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)aA1"

curl -X POST http://API-GATEWAY-IP:8100/api/customers \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"POC User\",\"email\":\"poc@example.com\",\"username\":\"pocuser\",\"password\":\"$POC_PASSWORD\",\"opening_deposit_cents\":500000}"
```

Log in:

```bash
TOKEN=$(curl -s -X POST http://API-GATEWAY-IP:8100/api/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"pocuser\",\"password\":\"$POC_PASSWORD\"}" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
```

Get account information:

```bash
curl http://API-GATEWAY-IP:8100/api/mobile/summary \
  -H "Authorization: Bearer $TOKEN"
```

Post a transfer:

```bash
curl -X POST http://API-GATEWAY-IP:8100/api/transfers \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account_id":"acct-checking","to_account_id":"acct-savings","amount_cents":12345,"description":"Manual test transfer"}'
```

Post a transfer to another registered user by username:

```bash
curl -X POST http://API-GATEWAY-IP:8100/api/transfers \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"from_account_id":"acct-checking","to_username":"alice","amount_cents":2500,"description":"Alex to Alice"}'
```

Look up a recipient before transferring:

```bash
curl "http://API-GATEWAY-IP:8100/api/recipients?username=alice" \
  -H "Authorization: Bearer $TOKEN"
```

## PIGGYBANK Register And Transfer Flow

The frontend adapter adds the PIGGYBANK login/register, transfer, mock banking screens, and Dev View controls to the mobile banking UI.

Use it to:

```text
Register  -> create a new username/password/customer/account set
Log In    -> sign in as any registered user
Transfer  -> click Send, choose a recipient from the registered-user dropdown, and send money to that user's checking account
```

After registering a user, the app logs in with the new credentials and refreshes balances automatically.

## Reconnect Cloned FLEX Components

After cloning every banking component to FLEX, run the reconnect script from this folder:

```bash
cd /home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/banking_poc
chmod +x BankSys-reconnect-flex.sh
./BankSys-reconnect-flex.sh
```

The script asks for the new FLEX IP of each component:

```text
Database
Cache
Auth
Audit
Notification
Core Banking
Ledger
API Gateway
Frontend
```

It then updates `/etc/banking-poc/*.env`, rewrites the frontend API proxy/config, restarts the systemd services, runs health checks, and saves the answers in `.banksys-flex.env`.

For production-like demos, a better long-term pattern is to reconnect components through stable DNS names such as `bank-api.flex.local` and `bank-db.flex.local` instead of hard-coded IPs. The reconnect script is best for a fast POC cutover, while DNS or service discovery is cleaner for repeated migrations.

Health checks:

```bash
curl http://FRONTEND-IP:8080/
curl http://API-GATEWAY-IP:8100/health
curl http://API-GATEWAY-IP:8100/ready
curl http://AUTH-IP:8101/health
curl http://CORE-IP:8102/health
curl http://LEDGER-IP:8103/health
curl http://AUDIT-IP:8104/health
curl http://NOTIFICATION-IP:8105/health
curl http://DATABASE-IP:8106/health
curl http://CACHE-IP:8107/health
```

## Systemd Operations

On a component server:

```bash
sudo systemctl status banking-api-gateway
sudo systemctl status banking-auth
sudo systemctl status banking-core-banking
sudo systemctl status banking-ledger
sudo systemctl status banking-audit
sudo systemctl status banking-notification
sudo systemctl status banking-database
sudo systemctl status banking-cache
```

View logs:

```bash
sudo journalctl -u banking-api-gateway -n 50 --no-pager
sudo journalctl -u banking-database -n 50 --no-pager
```

Restart a service:

```bash
sudo systemctl restart banking-api-gateway
```

## Installed Paths

On each server, component code is installed under:

```text
/opt/banking-poc
```

Environment files are installed under:

```text
/etc/banking-poc
```

Systemd units are installed under:

```text
/etc/systemd/system/banking-*.service
```

Frontend files are served from:

```text
/var/www/bankvault
```

## Troubleshooting

If SSH fails:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@SERVER-IP
```

If a component is unhealthy:

```bash
sudo systemctl status banking-COMPONENT
sudo journalctl -u banking-COMPONENT -n 80 --no-pager
```

If API Gateway `/ready` fails, check that these URLs were entered correctly during install:

```text
BANK_AUTH_URL
BANK_CORE_URL
BANK_LEDGER_URL
BANK_CACHE_URL
```

If Ledger transfers fail, check:

```text
BANK_DATABASE_URL
BANK_AUDIT_URL
BANK_NOTIFICATION_URL
```

If Database Service fails with MySQL:

```bash
sudo systemctl status mysql
sudo systemctl status banking-database
curl http://127.0.0.1:8106/health
```

If Database Service fails with PostgreSQL:

```bash
sudo systemctl status postgresql
sudo systemctl status banking-database
curl http://127.0.0.1:8106/health
```

If Cache Service fails:

```bash
sudo systemctl status redis-server
sudo systemctl status banking-cache
curl http://127.0.0.1:8107/health
```

## Demo Logins

The installer seeds two default users:

```text
username: alex
password: demo
customer_id: cust-1001

username: alice
password: demo
customer_id: cust-1002
```

The end-to-end business test creates a fresh user every time, so repeated tests do not depend on the default accounts. The frontend register panel can create more users directly from the mobile app.
