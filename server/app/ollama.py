"""Server-side Ollama access, with per-role model gating.

The browser never talks to Ollama. It doesn't learn the rig's address and it
can't reach it anyway — every request goes through here, which is what makes
the gating meaningful rather than advisory.

The gate, per Miles' requirement: a non-admin may use a model that is
**already resident in VRAM**, plus any **cloud** model. So a friend can chat
with whatever is warm and with the hosted models, but cannot cause a cold 18
GB load and evict what the admin is using. An admin may use anything.
"""
from __future__ import annotations

from typing import Any, AsyncIterator

import httpx

from .config import settings


class ModelNotAllowed(Exception):
    """Raised when a user asks for a model their role may not use."""

    def __init__(self, model: str, allowed: list[str]) -> None:
        self.model = model
        self.allowed = allowed
        super().__init__(
            f"'{model}' isn't available to you. It has to be loaded on the "
            f"server already, or be a cloud model."
        )


def _headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    # Ollama Cloud models need the account token. Held here and never sent to
    # a client.
    if settings.ollama_token:
        headers["Authorization"] = f"Bearer {settings.ollama_token}"
    return headers


def is_cloud_model(entry: dict[str, Any]) -> bool:
    """Cloud models report size 0 — they're references, not local weights.

    The name check is a belt-and-braces second signal; `nomic-embed-text` is
    0.3 GB and must not be mistaken for one.
    """
    if entry.get("size") == 0:
        return True
    name = str(entry.get("name") or entry.get("model") or "").lower()
    return name.endswith(":cloud") or "-cloud" in name


class OllamaProxy:
    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.ollama_url.rstrip("/"),
            timeout=httpx.Timeout(connect=6.0, read=300.0, write=30.0, pool=6.0),
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def installed(self) -> list[dict[str, Any]]:
        response = await self._client.get("/api/tags", headers=_headers())
        response.raise_for_status()
        return response.json().get("models") or []

    async def resident(self) -> set[str]:
        """Names of models currently held in VRAM, per /api/ps."""
        try:
            response = await self._client.get("/api/ps", headers=_headers())
            response.raise_for_status()
        except httpx.HTTPError:
            # If /api/ps can't be read we must not guess generously — an
            # empty set means non-admins get cloud models only, which fails
            # closed rather than opening the GPU up.
            return set()
        return {m.get("name", "") for m in (response.json().get("models") or [])}

    async def catalogue(self, *, is_admin: bool) -> list[dict[str, Any]]:
        """Models this role may use, annotated for the UI."""
        installed = await self.installed()
        resident = await self.resident()

        catalogue: list[dict[str, Any]] = []
        for entry in installed:
            name = entry.get("name", "")
            cloud = is_cloud_model(entry)
            loaded = name in resident
            # Embedding models can't hold a conversation.
            if "embed" in name.lower():
                continue
            allowed = is_admin or cloud or loaded
            catalogue.append({
                "name": name,
                "size": entry.get("size", 0),
                "cloud": cloud,
                "loaded": loaded,
                "allowed": allowed,
                # Said plainly, so the UI doesn't have to infer the reason.
                "reason": None if allowed else "Not loaded on the server",
            })

        # Usable first, then loaded, then alphabetical.
        catalogue.sort(key=lambda m: (not m["allowed"], not m["loaded"], m["name"]))
        return catalogue

    async def assert_allowed(self, model: str, *, is_admin: bool) -> None:
        if is_admin:
            return
        catalogue = await self.catalogue(is_admin=False)
        allowed = [m["name"] for m in catalogue if m["allowed"]]
        if model not in allowed:
            raise ModelNotAllowed(model, allowed)

    async def chat_stream(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        system_prompt: str | None = None,
    ) -> AsyncIterator[bytes]:
        """Streams Ollama's NDJSON chat response straight through.

        Passed through rather than parsed and re-emitted so the client gets
        tokens as Ollama produces them; buffering here would add the whole
        generation time to first-token latency.
        """
        payload: dict[str, Any] = {
            "model": model,
            "messages": (
                [{"role": "system", "content": system_prompt}] if system_prompt else []
            ) + messages,
            "stream": True,
        }

        async with self._client.stream(
            "POST", "/api/chat", json=payload, headers=_headers()
        ) as response:
            if response.status_code != 200:
                body = (await response.aread()).decode("utf-8", "replace")[:500]
                raise httpx.HTTPStatusError(
                    f"Ollama returned {response.status_code}: {body}",
                    request=response.request,
                    response=response,
                )
            async for chunk in response.aiter_bytes():
                yield chunk


proxy = OllamaProxy()
