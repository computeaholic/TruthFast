"""Compatibility import for the canonical ThreadForge FastAPI application.

The authoritative secondary HTTP application lives at ``runtime.api.app:app``.
This module intentionally defines no independent FastAPI instance, routers,
identity extraction, or authorization policy. Keeping this import alias avoids
breaking legacy importers while preventing ``api.app:app`` from becoming a
second runtime authority surface.
"""

from runtime.api.app import app

__all__ = ["app"]
