# =============================================================================
# ThreadForge — Replay Authority Context
# Phase 11: Authority Replay & Cryptographic Verification (READ-ONLY)
# runtime/authority/replay_context.py
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Tuple

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext


@dataclass(frozen=True)
class ReplayAuthorityContext:
    """Reconstructed authority context from stored artifacts.

    Phase 11: Reconstructs the exact authority state that existed at decision time.
    Performs structural validation only (types, presence).
    """

    identity: IdentityContext
    capabilities: CapabilitySet
    delegation_ids: Tuple[str, ...]
    policy_hash: str
    timestamp: datetime
