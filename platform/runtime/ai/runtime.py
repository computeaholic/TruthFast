# ============================================================================
# ThreadForge — Operator-AI Runtime Bootstrap
# Location: operator/ai/runtime.py
# ============================================================================

from __future__ import annotations

from runtime.ai.operator_core import OperatorCore
from runtime.ai.operator_daemon import OperatorAIBrainstem
from runtime.ai.traffic import TrafficRouter
from runtime.ai.vector_router import VectorRouterV2
from runtime.core.signal_fabric import SignalFabric
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.signal.fabric import subscribe
from runtime.smp.dispatcher import SMPDispatcher

_fabric: SignalFabric | None = None
_traffic: TrafficRouter | None = None
_core: OperatorCore | None = None
_daemon: OperatorAIBrainstem | None = None
_dispatcher: SMPDispatcher | None = None
_bootstrapped: bool = False


def bootstrap():
    """Initialize the runtime operator components.

    Idempotent: safe to call multiple times (only initializes once).
    Called automatically by operator_core() accessor on first use,
    or explicitly by FastAPI app startup event.

    This is the ONLY way to initialize the operator. No separate
    daemon process, no background threads, no polling loops.
    """
    global _fabric, _traffic, _core, _daemon, _dispatcher, _bootstrapped

    # Idempotency guard: only bootstrap once per process
    if _bootstrapped:
        return True

    # 1. Messaging fabric
    _fabric = SignalFabric()

    # 2. Initialize ledger service
    ledger = OperatorLedger()

    # 3. Wire ledger as signal subscriber
    subscribe("STORAGE_EVENT", ledger.record_event)

    # 4. Vector router (semantic routing / execution)
    vector_router = VectorRouterV2()

    # 5. Operator Core (explicit dependency injection)
    _core = OperatorCore(
        ledger=ledger,
        vector_router=vector_router,
        signal_fabric=_fabric,
    )

    # 6. Traffic router (API + CLI entry)
    _traffic = TrafficRouter(_core)

    # 7. Operator-AI Brainstem (PHASE 0: DISARMED — callable but not auto-started)
    # ========================================================================
    # CONTAINMENT: Brainstem remains accessible but does NOT auto-execute.
    # Previous behavior: Daemon thread auto-start at bootstrap (VIOLATED "no background jobs")
    # Current behavior: Component instantiated but inert (callable via API only)
    #
    # See: /tmp/FORENSIC_AUTONOMOUS_EXECUTION_REPORT.md (Phase 0 containment)
    #      .github/copilot-instructions.md (Deterministic Bootstrapping: no hidden schedulers)
    #
    # This is reversible disarming, not removal. The component API surface is preserved
    # for Phase 1 architectural redesign (brainstem as HTTP API, not daemon).
    # ========================================================================
    _daemon = OperatorAIBrainstem(interval_sec=3.0)
    _daemon.attach_fabric(_fabric)
    # _daemon.start()  # ← DISARMED: No auto-start of background thread
    # Brainstem is now accessible via get_brainstem() for operator-initiated operations only.

    _bootstrapped = True
    return True


# ---------------------------------------------------------
# Accessors
# ---------------------------------------------------------
def fabric() -> SignalFabric:
    if _fabric is None:
        raise RuntimeError("SignalFabric not initialized; call bootstrap() first")
    return _fabric


def traffic() -> TrafficRouter:
    if _traffic is None:
        raise RuntimeError("TrafficRouter not initialized; call bootstrap() first")
    return _traffic


def operator_core() -> OperatorCore:
    global _core
    if _core is None:
        bootstrap()
    if _core is None:
        raise RuntimeError("OperatorCore not initialized after bootstrap")
    return _core


def dispatcher() -> SMPDispatcher:
    if _core is None or _core.dispatcher is None:
        raise RuntimeError("Operator runtime not initialized; call bootstrap() first")
    return _core.dispatcher


def get_brainstem() -> OperatorAIBrainstem:
    """Get the Operator-AI Brainstem component.

    NOTE (Phase 0 Containment): The brainstem is NO LONGER auto-started at bootstrap.
    It is callable on-demand for Phase 1 architectural redesign (API-based governance).

    Current status: INERT (not running) — component callable via this accessor only.

    See: /tmp/FORENSIC_AUTONOMOUS_EXECUTION_REPORT.md (Phase 0 analysis)
    """
    if _daemon is None:
        raise RuntimeError("OperatorAIBrainstem not initialized; call bootstrap() first")
    return _daemon


def get_brainstem_service():
    """Get BrainstemService (governance engine) for operator-initiated operations.

    Phase 2: HTTP API surface wraps brainstem logic via this service.
    Service methods:
      - observe(spiffe_id) → read-only snapshot (signals only, no intent ledger)
      - propose(verdict, spiffe_id) → plan generation (creates intent ledger entry)
      - execute(verdict, spiffe_id, governance_action_id) → execution (pre+post ledger)

    All operations are identity-gated (SPIFFE required) and operator-supervised
    (no background threads or auto-execution).

    Returns:
        BrainstemService instance wrapping the inert brainstem component

    Raises:
        RuntimeError: If brainstem not initialized
    """
    from runtime.ai.brainstem_service import BrainstemService

    if _daemon is None:
        raise RuntimeError("Brainstem not initialized; call bootstrap() first")
    return BrainstemService(_daemon)
