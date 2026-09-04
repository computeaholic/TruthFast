# =============================================================================
# ThreadForge — Verification Result
# Phase 11: Authority Replay & Cryptographic Verification (READ-ONLY)
# runtime/authority/verification_result.py
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Tuple


@dataclass(frozen=True)
class VerificationResult:
    """Structured, human- and machine-readable verification output.

    Phase 11: Pure verification result with no side effects.
    """

    verified: bool
    reason: str
    mismatches: Tuple[str, ...]
    verified_at: datetime
