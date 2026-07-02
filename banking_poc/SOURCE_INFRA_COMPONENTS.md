# BankSys Source Infra Components

Target OS for every component: Ubuntu 24.04 LTS.

Use the current WSL Ubuntu SSH key by default:

```bash
~/.ssh/id_rsa
```

## Recommended OSPC Components

| Component | OSPC Flavor | OS | Installs | Public/App Port | Local Engine Port |
|---|---|---|---|---:|---:|
| Frontend Web / Mobile App | `m1.small` or 1-2 vCPU / 2 GB RAM | Ubuntu 24.04 | nginx, static mobile HTML, API adapter | `8080` | n/a |
| API Gateway / Mobile API | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8100` | n/a |
| Auth / Identity Service | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8101` | n/a |
| Core Banking Backend | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8102` | n/a |
| Ledger / Transfer Service | `m1.medium` or 2 vCPU / 4 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8103` | n/a |
| Audit / Compliance Log | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8104` | n/a |
| Notification Service | `m1.small` or 1 vCPU / 2 GB RAM | Ubuntu 24.04 | Python 3 service, systemd unit | `8105` | n/a |
| Database Service | `m1.large` or 4 vCPU / 8 GB RAM, 50+ GB volume | Ubuntu 24.04 | MySQL Server + PyMySQL, or PostgreSQL + psycopg2, plus Python 3 DB API service | `8106` | `3306` MySQL local only, or `5432` PostgreSQL local only |
| Cache Service | `m1.small` or 1-2 vCPU / 2 GB RAM | Ubuntu 24.04 | Redis Server, redis-tools, Python 3 cache API service | `8107` | `6379` local only |

## Small POC Layout

For a compact demo, use five VMs:

| VM | Components |
|---|---|
| VM 1 | Frontend |
| VM 2 | API Gateway |
| VM 3 | Auth + Core Banking |
| VM 4 | Ledger + Audit + Notification |
| VM 5 | Database + Cache |

For the simplest lab, all components can run on one Ubuntu 24.04 VM. Enter the same IP for every installer prompt.

## Network Rules

Allow SSH from your WSL/client host:

```text
TCP 22
```

Allow the app/component ports between POC servers:

```text
TCP 8080  Frontend
TCP 8100  API Gateway
TCP 8101  Auth
TCP 8102  Core Banking
TCP 8103  Ledger
TCP 8104  Audit
TCP 8105  Notification
TCP 8106  Database Service API
TCP 8107  Cache Service API
```

Do not expose MySQL, PostgreSQL, or Redis directly for this POC unless you explicitly need to debug them:

```text
TCP 3306  MySQL, local to Database server
TCP 5432  PostgreSQL, local to Database server
TCP 6379  Redis, local to Cache server
```

Other components talk to the selected database engine and Redis through the POC Database Service and Cache Service HTTP APIs.

## Installed Engines

The interactive installer installs the runtime engines on the correct servers:

| Server | Engine |
|---|---|
| Database Server | MySQL Server or PostgreSQL from Ubuntu 24 packages |
| Cache Server | Redis Server from Ubuntu 24 packages |
| Frontend Server | nginx |
| App Servers | Python 3 services managed by systemd |

The interactive installer prompts for the database engine:

```text
Database engine on Database server: mysql or postgresql [mysql]:
```
