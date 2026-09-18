"""Passwords, sessions and the role checks the routes depend on.

Session design: a random 256-bit token goes to the client in a cookie, and
only its SHA-256 hash is stored. So a dumped database yields no usable
sessions, and there's nothing to decrypt — the token is a bearer secret, not
a container for claims. That's deliberately not JWT: revoking a JWT means
maintaining a denylist anyway, and there's no second service to validate it.
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
import sqlite3
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from fastapi import Cookie, Depends, HTTPException, Request, status

from . import db
from .config import settings

SESSION_COOKIE = "horizon_session"

# Argon2id at the library defaults, which track current guidance. Tuning
# these down to speed up login is a false economy.
_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(stored_hash: str, password: str) -> bool:
    try:
        _hasher.verify(stored_hash, password)
        return True
    except (VerifyMismatchError, InvalidHashError, Exception):
        return False


def needs_rehash(stored_hash: str) -> bool:
    try:
        return _hasher.check_needs_rehash(stored_hash)
    except Exception:
        return False


def _token_hash(token: str) -> str:
    """Hash a session token. Salt-free on purpose: the token is already 256
    bits of entropy, so there's no dictionary to defend against, and a
    deterministic hash is what makes the primary-key lookup possible."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


# ----------------------------------------------------------------------------
# Login throttling
# ----------------------------------------------------------------------------

def _prune_attempts(conn: sqlite3.Connection, cutoff: int) -> None:
    conn.execute("DELETE FROM login_attempts WHERE attempted_at < ?", (cutoff,))


def is_locked_out(username: str) -> bool:
    cutoff = db.now() - settings.login_window_seconds
    with db.connect() as conn:
        _prune_attempts(conn, cutoff)
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM login_attempts "
            "WHERE username = ? AND attempted_at >= ?",
            (username.lower(), cutoff),
        ).fetchone()
    return (row["n"] if row else 0) >= settings.login_max_attempts


def record_failed_attempt(username: str) -> None:
    db.execute(
        "INSERT INTO login_attempts (username, attempted_at) VALUES (?, ?)",
        (username.lower(), db.now()),
    )


def clear_attempts(username: str) -> None:
    db.execute("DELETE FROM login_attempts WHERE username = ?", (username.lower(),))


# ----------------------------------------------------------------------------
# Users and sessions
# ----------------------------------------------------------------------------

def create_user(username: str, password: str, role: str = "user") -> str:
    if role not in {"admin", "user"}:
        raise ValueError(f"unknown role: {role}")
    username = username.strip()
    if len(username) < 2:
        raise ValueError("username must be at least 2 characters")
    if len(password) < 10:
        # Length over composition rules: a long passphrase beats a short
        # password with a digit bolted on, and these accounts are handed out
        # by an admin rather than chosen under duress.
        raise ValueError("password must be at least 10 characters")

    user_id = db.new_id()
    try:
        db.execute(
            "INSERT INTO users (id, username, password_hash, role, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (user_id, username, hash_password(password), role, db.now()),
        )
    except sqlite3.IntegrityError as error:
        raise ValueError(f"username '{username}' is taken") from error
    return user_id


def authenticate(username: str, password: str) -> sqlite3.Row | None:
    row = db.one(
        "SELECT * FROM users WHERE username = ? COLLATE NOCASE", (username.strip(),)
    )
    if row is None:
        # Hash anyway, so a missing user and a wrong password take the same
        # time. Otherwise the response time enumerates valid usernames.
        hash_password(password)
        return None
    if row["disabled"]:
        return None
    if not verify_password(row["password_hash"], password):
        return None
    if needs_rehash(row["password_hash"]):
        db.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (hash_password(password), row["id"]),
        )
    return row


def start_session(user_id: str, user_agent: str | None) -> tuple[str, int]:
    """Returns (token, expires_at). The token is never stored."""
    token = secrets.token_urlsafe(32)
    expires_at = db.now() + settings.session_days * 86400
    db.execute(
        "INSERT INTO sessions (token_hash, user_id, created_at, expires_at, user_agent) "
        "VALUES (?, ?, ?, ?, ?)",
        (_token_hash(token), user_id, db.now(), expires_at, (user_agent or "")[:300]),
    )
    return token, expires_at


def end_session(token: str) -> None:
    db.execute("DELETE FROM sessions WHERE token_hash = ?", (_token_hash(token),))


def end_all_sessions(user_id: str) -> None:
    db.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))


def _lookup_session(token: str) -> sqlite3.Row | None:
    row = db.one(
        "SELECT s.expires_at, u.* FROM sessions s "
        "JOIN users u ON u.id = s.user_id "
        "WHERE s.token_hash = ?",
        (_token_hash(token),),
    )
    if row is None:
        return None
    if row["expires_at"] < db.now():
        end_session(token)
        return None
    if row["disabled"]:
        return None
    return row


# ----------------------------------------------------------------------------
# FastAPI dependencies
# ----------------------------------------------------------------------------

async def current_user(
    session: str | None = Cookie(default=None, alias=SESSION_COOKIE),
) -> sqlite3.Row:
    if not session:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not signed in")
    row = _lookup_session(session)
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session expired")
    return row


async def require_admin(user: sqlite3.Row = Depends(current_user)) -> sqlite3.Row:
    if user["role"] != "admin":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admins only")
    return user


async def require_json(request: Request) -> None:
    """Rejects state-changing requests that aren't JSON.

    With SameSite=Lax cookies a cross-site POST doesn't carry the session
    anyway, but requiring a JSON content type closes the form-submission path
    too: a browser can't send application/json cross-origin without a CORS
    preflight, which this app doesn't grant.
    """
    if request.method in {"GET", "HEAD", "OPTIONS"}:
        return
    content_type = request.headers.get("content-type", "")
    if not content_type.startswith("application/json"):
        raise HTTPException(
            status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            "Expected application/json",
        )


def bootstrap_admin_if_needed() -> None:
    """Creates the first admin from the environment, if there are no users.

    Only on a genuinely empty users table, so restarting the container can't
    resurrect or reset an account that was deliberately removed.
    """
    row = db.one("SELECT COUNT(*) AS n FROM users")
    if row and row["n"]:
        return
    if not (settings.bootstrap_admin and settings.bootstrap_password):
        print(
            "No users yet, and BOOTSTRAP_ADMIN_USERNAME / "
            "BOOTSTRAP_ADMIN_PASSWORD are unset — nobody can sign in. "
            "Set both and restart."
        )
        return
    create_user(settings.bootstrap_admin, settings.bootstrap_password, role="admin")
    print(f"Created initial admin '{settings.bootstrap_admin}'.")


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())
