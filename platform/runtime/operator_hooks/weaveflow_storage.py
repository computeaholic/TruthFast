# ==============================================================================
# ThreadForge — WeaveFlow Storage Hooks
# Path: operator/operator_hooks/weaveflow_storage.py
# ------------------------------------------------------------------------------
# Ensures WeaveFlow events get durably stored in tf-events bucket via Operator-AI.
# ==============================================================================

from __future__ import annotations

import json
import time

from runtime.ai.traffic import TrafficRouter
from runtime.authority.state import is_authoritative
from runtime.core.signal_fabric import FabricEnvelope as Envelope


class WeaveFlowStorageHook:
    def __init__(self, router: TrafficRouter):
        self.router = router

    def emit(self, event: dict):
        ts = int(time.time())
        lineage = event.get("lineage", "unknown")
        object_name = f"weaveflow-{lineage}-{ts}.jsonl"

        # Enforce P1: refuse to enqueue storage writes when runtime is non-authoritative
        if not is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot perform weaveflow storage write")

        env = Envelope(
            sender="weaveflow",
            recipient="operator-ai",
            payload={
                "op": "storage.write",
                "bucket": "tf-events",
                "object": object_name,
                "lineage": lineage,
                "data": json.dumps(event).encode("utf-8"),
            },
        )

        return self.router._dispatch(env)
