# ==============================================================================
# ThreadForge — CivSim Storage Hooks
# Path: operator/operator_hooks/civsim_storage.py
# ------------------------------------------------------------------------------
# CivSim emits envelopes like:
#   {
#       "world": <bytes>,
#       "lineage": <str>,
#       "tick": <int>,
#       ...
#   }
# This hook saves world-state snapshots to MinIO using Operator-AI traffic.
# ==============================================================================

from __future__ import annotations

import time

from runtime.ai.traffic import TrafficRouter
from runtime.core.signal_fabric import FabricEnvelope as Envelope


class CivSimStorageHook:
    def __init__(self, router: TrafficRouter):
        self.router = router

    def save_snapshot(self, world_bytes: bytes, lineage: str, tick: int):
        object_name = f"civsim-{lineage}-{tick}-{int(time.time())}.bin"

        env = Envelope(
            sender="civsim",
            recipient="operator-ai",
            payload={
                "op": "storage.write",
                "bucket": "tf-sim",
                "object": object_name,
                "lineage": lineage,
                "data": world_bytes,
            },
        )

        return self.router._dispatch(env)
