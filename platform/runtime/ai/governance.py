# ==============================================================================
# ThreadForge — AI Governance Stubs
# Path: runtime/ai/governance.py
# ==============================================================================

"""Stub implementations for governance components.
These will be replaced with full implementations during governance integration.
"""

from __future__ import annotations

from typing import Any


class REG:
    """Reflex Epoch Governance - Stub"""

    @staticmethod
    def validate_epoch(epoch: int) -> None:
        pass

    @staticmethod
    def advance_epoch(epoch: int) -> None:
        pass


class CSched:
    """Cognitive Scheduler - Stub"""

    @staticmethod
    def preprocess(state: Any, envelope: Any) -> None:
        pass

    @staticmethod
    def current_load() -> float:
        return 0.5


class PolComp:
    """Policy Compiler - Stub"""

    @staticmethod
    def validate(envelope: Any) -> None:
        pass


class ACL:
    """Agent Causal Ledger - Stub"""

    @staticmethod
    def record_inbound(envelope: Any) -> None:
        pass

    @staticmethod
    def record_outbound(envelope: Any, payload: Any) -> None:
        pass

    @staticmethod
    def record_error(envelope: Any, exc: Exception) -> None:
        pass
