# Blue/Green Cutover Tester

The Blue/Green Cutover Tester runs on a source jumphost and validates source and
target application endpoints before production cutover.

It runs in simulation mode by default. It does not move real production traffic
unless a real switcher is added later.

## Deployment

Install on a source jumphost:

```bash
cd /tmp/blue-green-cutover-app
bash install_cutover_app.sh
```

Expected ports:

- Backend API: `8000`
- Frontend UI: `8080`

UI:

```text
http://SOURCE_JUMPHOST_IP:8080
```

API docs:

```text
http://SOURCE_JUMPHOST_IP:8000/docs
```

## CLI Test

```bash
cd /opt/blue-green-cutover-app
export SOURCE_URL=http://SOURCE_SERVER_IP:APP_PORT
export TARGET_URL=http://TARGET_SERVER_IP:APP_PORT
bash test_cutover_from_cli.sh
```

## Why Source Jumphost

The source jumphost usually has network access to:

- source app
- target app
- migration network
- load balancer or DNS automation endpoint

Source and target servers do not need an agent. They only need reachable app
URLs or health endpoints.

## Security

Do not expose this tester publicly without protection. Restrict ports `8000`
and `8080` to private/admin networks or security groups.

Later enhancements can add API key auth, TLS, login, RBAC, and real HAProxy,
Octavia, DNS, NGINX, or Kubernetes switchers.
