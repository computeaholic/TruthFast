# =====================================================================
# ThreadForge — SMP API Endpoint (v2.0)
# Path: api/routes/smp.py
# =====================================================================

from fastapi import APIRouter, Depends

from api.deps import extract_spiffe_identity
from api.smp_http import SMPRequest, to_smp
from runtime.protocols.smp.command_bus import CommandBus
from runtime.protocols.smp.navbus import NavBus
from runtime.protocols.smp.navbus_dispatcher import AgentRegistry, NavBusDispatcher

# ================================================================
# Runtime Bus + Dispatcher Setup (global singleton)
# ================================================================
bus = NavBus()
registry = AgentRegistry()
dispatcher = NavBusDispatcher(bus, registry)

# Register default ella-core agent
registry.register("ella-core", lambda env: {"ok": env.op})

# Attach CommandBus layer
cmd_bus = CommandBus(bus, dispatcher)

# ================================================================
# FastAPI Router
# ================================================================
router = APIRouter()


@router.post("/command")
def smp_command(req: SMPRequest, spiffe_id: str = Depends(extract_spiffe_identity)):
    """HTTP → SMP → NavBus → Dispatcher → Ella-Core

    Identity enforcement: All requests must provide valid SPIFFE ID.
    Identity is propagated through the envelope for downstream authorization.
    """
    env = to_smp(req, cmd_bus)

    # Inject validated identity into envelope metadata
    if not hasattr(env, "metadata"):
        env.metadata = {}
    env.metadata["x-spiffe-id"] = spiffe_id

    cmd_bus.submit(env)
    resp = dispatcher.dispatch_next()

    return {
        "status": "ok" if resp else "error",
        "result": resp,
        "trace_id": env.trace_id,
    }
