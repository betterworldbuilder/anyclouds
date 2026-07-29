"""GitHub OAuth for the AI Adoption routes.

The dashboard has no authentication and binds 0.0.0.0 (letsmove.sh), while this
feature clones untrusted repositories and accepts uploaded archives. That
combination is the reason this module exists: every mutating AI Adoption route
is gated here.

Access token handling: the token is used once, in-process, to identify the user
and (optionally) check org membership, then discarded. It is never written to
the session, never persisted, and never logged. Only the resolved login is kept.
"""

from __future__ import annotations

import functools
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional, Tuple

from flask import jsonify, redirect, request, session

GITHUB_AUTHORIZE = "https://github.com/login/oauth/authorize"
GITHUB_TOKEN = "https://github.com/login/oauth/access_token"
GITHUB_API = "https://api.github.com"

SESSION_KEY = "ai_adoption_user"
STATE_KEY = "ai_adoption_oauth_state"

_LOOPBACK = {"127.0.0.1", "::1", "localhost"}


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def is_configured() -> bool:
    return bool(_env("AI_ADOPTION_GITHUB_CLIENT_ID") and _env("AI_ADOPTION_GITHUB_CLIENT_SECRET"))


def allow_loopback() -> bool:
    """Loopback bypass, on by default.

    Without it, configuring an OAuth app would be mandatory just to open the
    dashboard on the machine running it. The bypass is strictly loopback: a
    request arriving over the public bind never qualifies.
    """
    return _env("AI_ADOPTION_ALLOW_LOOPBACK", "1") not in ("0", "false", "no")


def _request_is_loopback() -> bool:
    # request.remote_addr is the peer address. Behind the nginx proxy on :5002
    # that is 127.0.0.1, which is correct: nginx itself is on this host. A
    # forwarded header is attacker-controlled and is deliberately not trusted.
    return (request.remote_addr or "") in _LOOPBACK


def current_user() -> Optional[Dict[str, Any]]:
    user = session.get(SESSION_KEY)
    return user if isinstance(user, dict) else None


def _actor() -> str:
    user = current_user()
    if user:
        return str(user.get("login") or "unknown")
    return "loopback" if _request_is_loopback() else "anonymous"


def _allowed(login: str, token: str) -> Tuple[bool, str]:
    """Apply the optional allow-lists. Empty config means any GitHub user."""
    logins = [x.strip().lower() for x in _env("AI_ADOPTION_ALLOWED_LOGINS").split(",") if x.strip()]
    if logins and login.lower() not in logins:
        return False, f"{login} is not in AI_ADOPTION_ALLOWED_LOGINS"

    org = _env("AI_ADOPTION_ALLOWED_ORG")
    if org:
        try:
            # 204 = member, 302/404 = not a member.
            _api(f"/orgs/{urllib.parse.quote(org)}/members/{urllib.parse.quote(login)}", token)
        except urllib.error.HTTPError as exc:
            if exc.code in (302, 404):
                return False, f"{login} is not a member of {org}"
            return False, f"membership check failed ({exc.code})"
        except Exception:
            return False, "membership check failed"
    return True, ""


def _api(path: str, token: str) -> Any:
    req = urllib.request.Request(
        GITHUB_API + path,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "CloudJumper-AI-Adoption",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = resp.read().decode("utf-8", "replace")
    return json.loads(body) if body.strip() else {}


def _redirect_uri() -> str:
    configured = _env("AI_ADOPTION_GITHUB_REDIRECT_URI")
    if configured:
        return configured
    # url_root already reflects the scheme/host nginx forwarded.
    return request.url_root.rstrip("/") + "/ai-adoption/auth/callback"


def login_start():
    if not is_configured():
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "GitHub OAuth is not configured",
                    "hint": "Set AI_ADOPTION_GITHUB_CLIENT_ID and AI_ADOPTION_GITHUB_CLIENT_SECRET",
                }
            ),
            503,
        )
    state = secrets.token_urlsafe(24)
    session[STATE_KEY] = state
    params = {
        "client_id": _env("AI_ADOPTION_GITHUB_CLIENT_ID"),
        "redirect_uri": _redirect_uri(),
        # read:org is only needed when AI_ADOPTION_ALLOWED_ORG is set; read:user
        # alone is enough to identify the caller. Keep the grant minimal.
        "scope": "read:user read:org" if _env("AI_ADOPTION_ALLOWED_ORG") else "read:user",
        "state": state,
        "allow_signup": "false",
    }
    return redirect(f"{GITHUB_AUTHORIZE}?{urllib.parse.urlencode(params)}")


def login_callback():
    if not is_configured():
        return jsonify({"ok": False, "error": "GitHub OAuth is not configured"}), 503

    expected = session.pop(STATE_KEY, None)
    supplied = request.args.get("state")
    # Constant-time compare, and reject when no state was ever issued.
    if not expected or not supplied or not secrets.compare_digest(str(expected), str(supplied)):
        return jsonify({"ok": False, "error": "OAuth state mismatch"}), 400

    code = request.args.get("code") or ""
    if not code:
        return jsonify({"ok": False, "error": "missing code"}), 400

    data = urllib.parse.urlencode(
        {
            "client_id": _env("AI_ADOPTION_GITHUB_CLIENT_ID"),
            "client_secret": _env("AI_ADOPTION_GITHUB_CLIENT_SECRET"),
            "code": code,
            "redirect_uri": _redirect_uri(),
        }
    ).encode()
    req = urllib.request.Request(
        GITHUB_TOKEN,
        data=data,
        headers={"Accept": "application/json", "User-Agent": "CloudJumper-AI-Adoption"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        # Deliberately vague: the upstream body can echo the client secret.
        return jsonify({"ok": False, "error": "token exchange failed"}), 502

    token = payload.get("access_token") or ""
    if not token:
        return jsonify({"ok": False, "error": "token exchange failed"}), 502

    try:
        who = _api("/user", token)
    except Exception:
        return jsonify({"ok": False, "error": "could not read GitHub profile"}), 502

    login = str(who.get("login") or "")
    if not login:
        return jsonify({"ok": False, "error": "could not read GitHub profile"}), 502

    ok, why = _allowed(login, token)
    # The token goes out of scope here and is never stored.
    del token
    if not ok:
        return jsonify({"ok": False, "error": "access denied", "detail": why}), 403

    session[SESSION_KEY] = {
        "login": login,
        "name": who.get("name") or login,
        "avatar_url": who.get("avatar_url") or "",
    }
    session.permanent = True
    return redirect("/ai-powerup")


def logout():
    session.pop(SESSION_KEY, None)
    session.pop(STATE_KEY, None)
    return jsonify({"ok": True})


def whoami():
    user = current_user()
    return jsonify(
        {
            "ok": True,
            "authenticated": bool(user),
            "user": user,
            "configured": is_configured(),
            "loopback_allowed": allow_loopback(),
            "loopback_request": _request_is_loopback(),
            "actor": _actor(),
        }
    )


def require_ai_auth(fn):
    """Gate a mutating route.

    Order matters: a signed-in user is always allowed; otherwise loopback is
    allowed when enabled; otherwise deny. When OAuth is unconfigured there is no
    way to sign in, so a remote caller is denied rather than let through — the
    insecure-by-default alternative is what this module exists to prevent.
    """

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        if current_user():
            return fn(*args, **kwargs)
        if allow_loopback() and _request_is_loopback():
            return fn(*args, **kwargs)
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "authentication required",
                    "login_url": "/ai-adoption/auth/login",
                    "configured": is_configured(),
                }
            ),
            401,
        )

    return wrapper
