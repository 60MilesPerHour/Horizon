"""Configuration, all from the environment.

Nothing here has a usable default that would let the service run insecurely:
SESSION_SECRET has no default at all, so a misconfigured deploy fails at
import rather than silently signing sessions with a known key.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field


def _require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(
            f"{name} is not set. Generate one with: "
            "python -c 'import secrets; print(secrets.token_urlsafe(48))'"
        )
    return value


def _flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    # Where the Ollama rig is. Reached server-side only — the browser never
    # talks to it, which is the whole point of proxying.
    ollama_url: str = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")

    # Bearer token for Ollama Cloud models. Held here, never sent to a client.
    ollama_token: str = os.environ.get("OLLAMA_TOKEN", "")

    database_path: str = os.environ.get("DATABASE_PATH", "/data/horizon-web.db")

    session_secret: str = field(default_factory=lambda: _require("SESSION_SECRET"))

    # How long a login lasts.
    session_days: int = int(os.environ.get("SESSION_DAYS", "30"))

    # Set false only for local plain-HTTP development. In production the
    # cookie must be Secure, or it travels in the clear.
    secure_cookies: bool = _flag("SECURE_COOKIES", True)

    # Comma-separated origins allowed to call the API. Empty means same-origin
    # only, which is the case when the Flutter bundle is served by this app.
    cors_origins: tuple[str, ...] = tuple(
        o.strip() for o in os.environ.get("CORS_ORIGINS", "").split(",") if o.strip()
    )

    # First-run bootstrap: creates this admin if the users table is empty.
    # Both must be set or no admin is made and the service tells you so.
    bootstrap_admin: str = os.environ.get("BOOTSTRAP_ADMIN_USERNAME", "")
    bootstrap_password: str = os.environ.get("BOOTSTRAP_ADMIN_PASSWORD", "")

    # Failed logins allowed per username per window before lockout.
    login_max_attempts: int = int(os.environ.get("LOGIN_MAX_ATTEMPTS", "8"))
    login_window_seconds: int = int(os.environ.get("LOGIN_WINDOW_SECONDS", "900"))


settings = Settings()
