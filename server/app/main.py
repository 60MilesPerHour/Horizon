"""HTTP API for the Horizon web client.

Serves the Flutter web bundle and the API from one origin, which is why CORS
is off by default: same-origin means no preflight to get wrong, and the
session cookie needs no cross-site relaxation.
"""
from __future__ import annotations

import sqlite3
from contextlib import asynccontextmanager
from typing import Annotated, Any, Literal

import httpx
from fastapi import (
    APIRouter, Depends, FastAPI, HTTPException, Request, Response, status,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import auth, db
from .config import settings
from .ollama import ModelNotAllowed, proxy

WEB_ROOT = "/srv/web"


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.initialize()
    auth.bootstrap_admin_if_needed()
    yield
    await proxy.close()


app = FastAPI(title="Horizon Web", lifespan=lifespan, docs_url=None, redoc_url=None)

if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_origins),
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "DELETE"],
        allow_headers=["Content-Type"],
    )


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    response.headers.setdefault("X-Frame-Options", "DENY")
    # Flutter web needs inline styles and a wasm-capable script policy; it
    # does not need to reach anything off-origin, so everything else is
    # locked to 'self'.
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; img-src 'self' data: blob:; "
        "style-src 'self' 'unsafe-inline'; font-src 'self' data:; "
        "script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; "
        "frame-ancestors 'none'; base-uri 'self'",
    )
    return response


api = APIRouter(prefix="/api", dependencies=[Depends(auth.require_json)])

CurrentUser = Annotated[sqlite3.Row, Depends(auth.current_user)]
AdminUser = Annotated[sqlite3.Row, Depends(auth.require_admin)]


# ----------------------------------------------------------------------------
# Schemas
# ----------------------------------------------------------------------------

class LoginBody(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class NewUserBody(BaseModel):
    username: str = Field(min_length=2, max_length=64)
    password: str = Field(min_length=10, max_length=256)
    role: Literal["admin", "user"] = "user"


class PasswordBody(BaseModel):
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=10, max_length=256)


class NewChatBody(BaseModel):
    model: str = Field(min_length=1, max_length=200)
    title: str = Field(default="New Chat", max_length=200)
    system_prompt: str | None = Field(default=None, max_length=8000)


class ChatPatchBody(BaseModel):
    title: str | None = Field(default=None, max_length=200)
    model: str | None = Field(default=None, max_length=200)
    system_prompt: str | None = Field(default=None, max_length=8000)


class SendBody(BaseModel):
    content: str = Field(min_length=1, max_length=200_000)


def _public_user(row: sqlite3.Row) -> dict[str, Any]:
    return {"id": row["id"], "username": row["username"], "role": row["role"]}


# ----------------------------------------------------------------------------
# Auth
# ----------------------------------------------------------------------------

@api.post("/auth/login")
async def login(body: LoginBody, request: Request, response: Response):
    if auth.is_locked_out(body.username):
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many failed attempts. Try again later.",
        )

    user = auth.authenticate(body.username, body.password)
    if user is None:
        auth.record_failed_attempt(body.username)
        # One message for every failure mode — wrong user, wrong password,
        # disabled account — so it reveals nothing.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")

    auth.clear_attempts(body.username)
    token, expires_at = auth.start_session(
        user["id"], request.headers.get("user-agent")
    )
    response.set_cookie(
        auth.SESSION_COOKIE,
        token,
        max_age=settings.session_days * 86400,
        httponly=True,
        secure=settings.secure_cookies,
        samesite="lax",
        path="/",
    )
    return {"user": _public_user(user), "expires_at": expires_at}


@api.post("/auth/logout")
async def logout(request: Request, response: Response):
    token = request.cookies.get(auth.SESSION_COOKIE)
    if token:
        auth.end_session(token)
    response.delete_cookie(auth.SESSION_COOKIE, path="/")
    return {"ok": True}


@api.get("/auth/me")
async def me(user: CurrentUser):
    return {"user": _public_user(user)}


@api.post("/auth/password")
async def change_password(body: PasswordBody, user: CurrentUser):
    if not auth.verify_password(user["password_hash"], body.current_password):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Current password is wrong")
    db.execute(
        "UPDATE users SET password_hash = ? WHERE id = ?",
        (auth.hash_password(body.new_password), user["id"]),
    )
    # Every other session belonged to the old password.
    auth.end_all_sessions(user["id"])
    return {"ok": True, "note": "All sessions signed out — sign in again."}


# ----------------------------------------------------------------------------
# Models
# ----------------------------------------------------------------------------

@api.get("/models")
async def list_models(user: CurrentUser):
    try:
        catalogue = await proxy.catalogue(is_admin=user["role"] == "admin")
    except httpx.HTTPError as error:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, f"Could not reach Ollama: {error}"
        ) from error
    return {"models": catalogue}


# ----------------------------------------------------------------------------
# Chats
# ----------------------------------------------------------------------------

def _owned_chat(chat_id: str, user: sqlite3.Row) -> sqlite3.Row:
    """Fetches a chat, scoped to its owner.

    Ownership is part of the WHERE clause rather than checked afterwards, so
    there's no path where a forgotten comparison leaks another user's chat.
    An admin gets no special access here: the role governs model use, not
    other people's conversations.
    """
    row = db.one(
        "SELECT * FROM chats WHERE id = ? AND user_id = ?", (chat_id, user["id"])
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such chat")
    return row


@api.get("/chats")
async def list_chats(user: CurrentUser):
    rows = db.query(
        "SELECT id, title, model, updated_at FROM chats "
        "WHERE user_id = ? ORDER BY updated_at DESC",
        (user["id"],),
    )
    return {"chats": [dict(r) for r in rows]}


@api.post("/chats", status_code=status.HTTP_201_CREATED)
async def create_chat(body: NewChatBody, user: CurrentUser):
    await _assert_model(body.model, user)
    chat_id = db.new_id()
    timestamp = db.now()
    db.execute(
        "INSERT INTO chats (id, user_id, title, model, system_prompt, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (chat_id, user["id"], body.title, body.model, body.system_prompt,
         timestamp, timestamp),
    )
    return {"chat": dict(db.one("SELECT * FROM chats WHERE id = ?", (chat_id,)))}


@api.get("/chats/{chat_id}")
async def get_chat(chat_id: str, user: CurrentUser):
    chat = _owned_chat(chat_id, user)
    messages = db.query(
        "SELECT id, role, content, created_at FROM messages "
        "WHERE chat_id = ? ORDER BY created_at, id",
        (chat_id,),
    )
    return {"chat": dict(chat), "messages": [dict(m) for m in messages]}


@api.patch("/chats/{chat_id}")
async def patch_chat(chat_id: str, body: ChatPatchBody, user: CurrentUser):
    chat = _owned_chat(chat_id, user)
    if body.model:
        await _assert_model(body.model, user)
    db.execute(
        "UPDATE chats SET title = ?, model = ?, system_prompt = ?, updated_at = ? "
        "WHERE id = ?",
        (
            body.title if body.title is not None else chat["title"],
            body.model or chat["model"],
            body.system_prompt if body.system_prompt is not None
            else chat["system_prompt"],
            db.now(),
            chat_id,
        ),
    )
    return {"chat": dict(db.one("SELECT * FROM chats WHERE id = ?", (chat_id,)))}


@api.delete("/chats/{chat_id}")
async def delete_chat(chat_id: str, user: CurrentUser):
    _owned_chat(chat_id, user)
    db.execute("DELETE FROM chats WHERE id = ?", (chat_id,))
    return {"ok": True}


async def _assert_model(model: str, user: sqlite3.Row) -> None:
    try:
        await proxy.assert_allowed(model, is_admin=user["role"] == "admin")
    except ModelNotAllowed as error:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            {"message": str(error), "allowed": error.allowed},
        ) from error
    except httpx.HTTPError as error:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, f"Could not reach Ollama: {error}"
        ) from error


@api.post("/chats/{chat_id}/messages")
async def send_message(chat_id: str, body: SendBody, user: CurrentUser):
    """Appends a user message and streams the reply.

    The model is re-checked here, not just at chat creation: a chat pinned to
    a model that has since been evicted from VRAM must not keep working for a
    non-admin, or the gate is bypassable simply by creating the chat while the
    model happened to be warm.
    """
    chat = _owned_chat(chat_id, user)
    await _assert_model(chat["model"], user)

    timestamp = db.now()
    db.execute(
        "INSERT INTO messages (id, chat_id, role, content, created_at) "
        "VALUES (?, ?, 'user', ?, ?)",
        (db.new_id(), chat_id, body.content, timestamp),
    )
    db.execute("UPDATE chats SET updated_at = ? WHERE id = ?", (timestamp, chat_id))

    history = [
        {"role": row["role"], "content": row["content"]}
        for row in db.query(
            "SELECT role, content FROM messages WHERE chat_id = ? "
            "ORDER BY created_at, id",
            (chat_id,),
        )
    ]

    async def stream():
        collected: list[str] = []
        try:
            async for chunk in proxy.chat_stream(
                model=chat["model"],
                messages=history,
                system_prompt=chat["system_prompt"],
            ):
                collected.append(chunk.decode("utf-8", "replace"))
                yield chunk
        except httpx.HTTPError as error:
            # Reported inside the stream: headers are already sent, so an
            # HTTP error code is no longer available to us.
            yield ('{"error":' + repr(str(error)).replace("'", '"') + "}\n").encode()
        finally:
            text = _assistant_text("".join(collected))
            if text:
                db.execute(
                    "INSERT INTO messages (id, chat_id, role, content, created_at) "
                    "VALUES (?, ?, 'assistant', ?, ?)",
                    (db.new_id(), chat_id, text, db.now()),
                )
                db.execute(
                    "UPDATE chats SET updated_at = ? WHERE id = ?",
                    (db.now(), chat_id),
                )

    return StreamingResponse(stream(), media_type="application/x-ndjson")


def _assistant_text(raw: str) -> str:
    """Reassembles the reply from Ollama's NDJSON stream.

    Done here as well as in the client because the transcript has to survive
    the browser closing mid-generation — a partial answer is still worth
    keeping, which is why this runs in the `finally`.
    """
    import json

    parts: list[str] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        message = payload.get("message") or {}
        parts.append(message.get("content") or "")
    return "".join(parts).strip()


# ----------------------------------------------------------------------------
# Admin
# ----------------------------------------------------------------------------

admin = APIRouter(prefix="/api/admin", dependencies=[Depends(auth.require_json)])


@admin.get("/users")
async def list_users(_: AdminUser):
    rows = db.query(
        "SELECT id, username, role, created_at, disabled FROM users ORDER BY username"
    )
    return {"users": [dict(r) for r in rows]}


@admin.post("/users", status_code=status.HTTP_201_CREATED)
async def add_user(body: NewUserBody, _: AdminUser):
    try:
        user_id = auth.create_user(body.username, body.password, body.role)
    except ValueError as error:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(error)) from error
    return {"user": {"id": user_id, "username": body.username, "role": body.role}}


@admin.post("/users/{user_id}/disable")
async def disable_user(user_id: str, actor: AdminUser):
    if user_id == actor["id"]:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "You can't disable yourself")
    db.execute("UPDATE users SET disabled = 1 WHERE id = ?", (user_id,))
    auth.end_all_sessions(user_id)
    return {"ok": True}


@admin.post("/users/{user_id}/enable")
async def enable_user(user_id: str, _: AdminUser):
    db.execute("UPDATE users SET disabled = 0 WHERE id = ?", (user_id,))
    return {"ok": True}


@admin.delete("/users/{user_id}")
async def delete_user(user_id: str, actor: AdminUser):
    if user_id == actor["id"]:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "You can't delete yourself")
    db.execute("DELETE FROM users WHERE id = ?", (user_id,))
    return {"ok": True}


app.include_router(api)
app.include_router(admin)


@app.get("/healthz")
async def healthz():
    return {"ok": True}


# The Flutter bundle, mounted last so it can't shadow the API. Unknown paths
# fall back to index.html for client-side routing.
try:
    app.mount("/", StaticFiles(directory=WEB_ROOT, html=True), name="web")
except RuntimeError:
    @app.get("/")
    async def no_bundle():
        return {
            "error": f"No web bundle at {WEB_ROOT}. "
            "Build it with: flutter build web --release"
        }
