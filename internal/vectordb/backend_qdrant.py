"""ThreadForge — Qdrant Backend (System-Level)
GPU-optimized vector search.
# Location: core/vectordb/backend_qdrant.py
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

import httpx


class QdrantBackend:
    def __init__(self):
        self.client = httpx.Client(timeout=30.0)
        self.base: str | None = None
        self.api_key: str | None = None

    def set_connection(self, base_url: str, api_key: str | None = None) -> None:
        if base_url is None:
            raise ValueError("Qdrant base_url cannot be None")
        self.base = base_url.rstrip("/")
        self.api_key = api_key

    # -------------------------------
    # Helpers
    # -------------------------------
    def _headers(self) -> dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self.api_key:
            h["api-key"] = self.api_key
        return h

    def _ensure_base(self) -> str:
        """Ensures `self.base` is set and is a valid string.
        Prevents 'None is not assignable to str' errors.
        """
        if not self.base:
            raise RuntimeError("QdrantBackend: Base URL not set. Call set_connection().")
        return self.base

    def _retry(self, fn: Callable[[], httpx.Response], retries: int = 3, delay: float = 0.25) -> httpx.Response:
        """Retry wrapper with proper 'raise ... from exc' for ruff B904 compatibility.
        Ensures we *always* return a Response or raise a final error.
        """
        last_exc: Exception | None = None

        for attempt in range(retries):
            try:
                resp = fn()
                if resp is None:
                    raise RuntimeError("Qdrant request returned None")
                resp.raise_for_status()
                return resp
            except Exception as exc:
                last_exc = exc
                if attempt < retries - 1:
                    time.sleep(delay)
                else:
                    # Required for Ruff B904 compliance.
                    raise last_exc from exc

        # Safety only; logic ensures we never reach this.
        raise RuntimeError("QdrantBackend retry failed unexpectedly")

    # -------------------------------
    # INSERT
    # -------------------------------
    def insert(self, req: Any) -> dict[str, Any]:
        base = self._ensure_base()
        url = f"{base}/collections/{req.namespace}/points"

        payload = {
            "points": [
                {
                    "id": req.id,
                    "vector": req.vector,
                    "payload": req.payload,
                },
            ],
        }

        self._retry(lambda: self.client.put(url, json=payload, headers=self._headers()))

        return {"backend": "qdrant", "status": "ok", "id": req.id}

    # -------------------------------
    # SEARCH
    # -------------------------------
    def search(self, req: Any) -> dict[str, Any]:
        base = self._ensure_base()
        url = f"{base}/collections/{req.namespace}/points/search"

        payload = {"vector": req.vector, "limit": req.top_k}

        resp = self._retry(lambda: self.client.post(url, json=payload, headers=self._headers()))

        return {
            "backend": "qdrant",
            "matches": resp.json().get("result", []),
        }

    # -------------------------------
    # DELETE
    # -------------------------------
    def delete(self, req: Any) -> dict[str, Any]:
        base = self._ensure_base()
        url = f"{base}/collections/{req.namespace}/points/delete"

        payload = {"points": [req.id]}

        self._retry(lambda: self.client.post(url, json=payload, headers=self._headers()))

        return {"backend": "qdrant", "status": "deleted", "id": req.id}
