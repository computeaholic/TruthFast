# =============================================================================
# ThreadForge — BackendSelector (Alpha / Bravo / Charlie)
# LLM Load-Balanced Cluster Selection
# runtime/ai/backend_selector.py
# =============================================================================

from __future__ import annotations

import random
from typing import Any

import requests


class LLMBackend:
    def __init__(self, name, url, weight=1, gpu=False):
        self.name = name
        self.url = url
        self.weight = weight
        self.gpu = gpu

    def generate(self, payload: dict[str, Any]):
        r = requests.post(f"{self.url}/generate", json=payload, timeout=60)
        r.raise_for_status()
        return r.json()


class BackendSelector:
    def __init__(self):
        # vLLM clusters
        # Identity is enforced at mesh level (SPIFFE + Istio mTLS).
        # BackendSelector performs load and capability selection only.
        self.backends = [
            # GPU-first cluster
            LLMBackend("vllm-alpha", "http://vllm-alpha.threadforge.svc.cluster.local:8000", weight=6, gpu=True),
            # CPU sidecar cluster
            LLMBackend("vllm-bravo", "http://vllm-bravo.threadforge.svc.cluster.local:8000", weight=3),
            # DR / cold cluster
            LLMBackend("vllm-charlie", "http://vllm-charlie.threadforge.svc.cluster.local:8000", weight=1),
        ]

    # ---------------------------------------------------------------------
    # MAIN SELECTION
    # ---------------------------------------------------------------------
    def select(
        self,
        civsim: str | None,
        score: float | None,
        priority: int,
        payload: dict[str, Any],
    ) -> LLMBackend:
        # High-priority → force GPU if available
        if priority >= 8 or (civsim and civsim == "high") or (score and score >= 7.0):
            gpu_backends = [b for b in self.backends if b.gpu]
            if gpu_backends:
                return gpu_backends[0]

        # Medium → weighted selection alpha/bravo
        if (civsim and civsim == "medium") or (score and score >= 4.0):
            weighted = []
            for b in self.backends[:2]:  # alpha + bravo
                weighted += [b] * b.weight
            return random.choice(weighted)  # nosec B311: Non-cryptographic; used for load balancing

        # Low → bravo or charlie
        weighted = []
        for b in self.backends[1:]:
            weighted += [b] * b.weight

        return random.choice(weighted)  # nosec B311: Non-cryptographic; used for load balancing
