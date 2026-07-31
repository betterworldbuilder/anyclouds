# Microsoft Entra ID single sign-on for the dashboard

Company email + password + Microsoft Authenticator, without this application
ever handling a credential.

```
browser ──TLS──▶ nginx :5002 ──auth_request──▶ oauth2-proxy :4180 ──▶ Entra ID
                    │                                                    │
                    │                          password + MFA happen here ┘
                    ▼
                 Flask :5001    receives only X-Auth-Request-* headers
```

**The dashboard has no login form and never will.** `/api/auth/login` returns
`501` when SSO is unconfigured rather than rendering a password box — a password
field not wired to Entra trains people to type company credentials into an
unauthenticated page, which is the habit SSO exists to remove.

## What already exists

| Piece | Where | Status |
|---|---|---|
| Identity resolution from SSO headers | `app.py` `_opencenter_lab_identity()` | built |
| Role (`Instructor`/`Student`) from group claims | same | built |
| Cohort from `X-Training-Cohort` | same | built |
| Per-learner isolated lab workspaces | `/api/opencenter/lab-session` | built |
| Header button + status | `_head_nav.html`, `/api/auth/whoami` | built |
| nginx site | `workflow_dashboard/osflex_nginx_sso.conf` | ready |
| oauth2-proxy config | `workflow_dashboard/oauth2-proxy.cfg.example` | ready |
| **Entra app registration** | your tenant | **you need this** |

The app registration is the only long pole, and it is an approval, not
engineering. Everything else is a config change.

---

## 1. Register the application in Entra

Entra admin center → **App registrations** → **New registration**.

| Field | Value |
|---|---|
| Name | `OSPC to FLEX Migration Dashboard` |
| Supported account types | **Single tenant** |
| Redirect URI | **Web** → `https://<PUBLIC_HOSTNAME>:5002/oauth2/callback` |

Then, still in the registration:

1. **Certificates & secrets** → **New client secret**. Copy the *Value*
   immediately; it is never shown again. Note the expiry and put a renewal
   reminder in the calendar — an expired secret is a silent total outage.
2. **Token configuration** → **Add optional claim** → *ID* → `email`,
   `preferred_username`.
3. **API permissions** → Microsoft Graph → *Delegated* → `openid`, `email`,
   `profile` → **Grant admin consent**.
4. *(Optional, for the Instructor role)* **Token configuration** →
   **Add groups claim** → *Security groups*. Then set `allowed_groups` and map
   the instructor group in `OPENCENTER_TRAINING_INSTRUCTORS`.

Record the **Directory (tenant) ID** and **Application (client) ID**.

### MFA / Microsoft Authenticator

Nothing to implement. MFA is a **Conditional Access policy** on the tenant,
applied to this app like any other. Ask your identity team to scope the existing
policy to include it. No dashboard code participates in — or can bypass — that
prompt.

## 2. Configure oauth2-proxy

```bash
cd workflow_dashboard
cp oauth2-proxy.cfg.example oauth2-proxy.cfg
chmod 600 oauth2-proxy.cfg
openssl rand -base64 32 | tr -- '+/' '-_'     # -> cookie_secret
$EDITOR oauth2-proxy.cfg                      # fill every <…>
echo 'workflow_dashboard/oauth2-proxy.cfg' >> ../.gitignore
oauth2-proxy --config "$PWD/oauth2-proxy.cfg"
```

## 3. Swap the nginx site

```bash
sudo cp workflow_dashboard/osflex_nginx_sso.conf /etc/nginx/conf.d/osflex.conf
sudo nginx -t && sudo systemctl reload nginx
```

> Running the **unprivileged** nginx from `letsmove.sh` instead? That script
> generates its config inline (`start_user_nginx`, around line 128) and will
> overwrite anything you put in `~/.cache/osflex-nginx/nginx.conf`. Port the
> `location` blocks from `osflex_nginx_sso.conf` into that heredoc, or switch to
> the system nginx path.

## 4. Turn it on in the app

```bash
export OPENCENTER_TRUST_SSO_HEADERS=1
export OPENCENTER_SSO_LOGIN_URL="/oauth2/start"
export OPENCENTER_SSO_LOGOUT_URL="/oauth2/sign_out"
export OPENCENTER_TRAINING_INSTRUCTORS="you@rackspace.com,colleague@rackspace.com"
export FLASK_SECRET_KEY="$(openssl rand -hex 32)"    # must persist across restarts
export WORKFLOW_DASHBOARD_HOST=127.0.0.1             # see the warning below
```

---

## Security checklist — do not skip

- [ ] **Bind Flask to `127.0.0.1`.** `letsmove.sh` line 24 currently forces
      `WORKFLOW_DASHBOARD_HOST=0.0.0.0`, so port 5001 answers on every
      interface. With `OPENCENTER_TRUST_SSO_HEADERS=1` set while 5001 is
      exposed, **anyone who can reach that port can send
      `X-Auth-Request-Email: ceo@rackspace.com` and become that user**, bypassing
      Entra entirely. Change that line, or firewall 5001, before enabling the flag.
- [ ] **Keep the header-blanking block** in `osflex_nginx_sso.conf`. nginx
      forwards unknown client headers verbatim; those `proxy_set_header … ""`
      lines are what stop a browser smuggling one in. If you add a header to
      `OPENCENTER_SSO_HEADERS`, add it there too.
- [ ] **A real TLS certificate.** The local CA from `letsmove.sh` is fine for a
      laptop and not for anything else.
- [ ] **`FLASK_SECRET_KEY` set and persistent.** Unset, `app.py` falls back to
      `os.urandom(32)`, so every restart silently invalidates all sessions.
- [ ] **`cookie_secret` is 32 bytes** and unique per environment.
- [ ] **Client secret expiry tracked.**
- [ ] `oauth2-proxy.cfg` is `chmod 600` and git-ignored.

## Verifying

```bash
# 1. Unauthenticated request redirects to Microsoft, not to the dashboard
curl -skI https://localhost:5002/ | head -1          # expect 302
# 2. The app sees the identity after sign-in (in the browser)
#    -> the header button shows your name and role
curl -sk https://localhost:5002/api/auth/whoami
# 3. Header spoofing is refused: this must NOT come back signed in
curl -sk -H 'X-Auth-Request-Email: nobody@example.com' \
     https://localhost:5002/api/auth/whoami
```

Check 3 is the one that matters. If it returns `signed_in: true`, the
header-blanking block is missing or Flask is reachable without going through
nginx — stop and fix that before letting anyone use it.

## Rolling back

```bash
unset OPENCENTER_TRUST_SSO_HEADERS
sudo cp workflow_dashboard/osflex_nginx.conf /etc/nginx/conf.d/osflex.conf
sudo nginx -t && sudo systemctl reload nginx
```

The dashboard returns to the manual Student/Instructor training login. No data
is tied to the SSO identity beyond the per-learner lab workspace hash.
