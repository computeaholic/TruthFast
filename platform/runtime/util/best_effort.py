"""Centralized helpers for best-effort, non-authoritative operations.

Use swallow_optional(context, exc) in except blocks that are intentionally
best-effort (metrics, emitters, Redis mirror, backpressure, non-authoritative
observability). This keeps logging consistent and avoids duplicated boilerplate.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def swallow_optional(context: str, exc: Exception) -> None:
    """Log a best-effort failure at DEBUG level.

    Args:
        context: Short human-friendly description of the failing operation.
        exc: The exception instance caught.
    """

    logger.debug(
        "Best-effort failure in %s: %s",
        context,
        exc,
        exc_info=True,
    )
