"""ThreadForge — Vector Routing Brain (System-Level)
# core/vectordb/router.py
Decides which backend to use based on:
- dimension
- payload weight
- namespace criticality
- real-time operator metrics

Operator-AI calls this through operator/vector/client_router.py
"""

from .backend_pgvector import PgVectorBackend
from .backend_qdrant import QdrantBackend


class VectorRouter:
    def __init__(self):
        self.pg = PgVectorBackend()
        self.qd = QdrantBackend()

    # ------------------------------------------------------------------
    # Main routing policy
    # ------------------------------------------------------------------
    def choose(self, req):
        dim = getattr(req, "dimension", 0)
        load = getattr(req, "load", 0)
        ns = getattr(req, "namespace", "")

        # High dimensions = GPU optimized Qdrant
        if dim > 2048:
            return self.qd

        # Heavy load conditions
        if load > 0.7:
            return self.qd

        # Sensitive namespaces use pgvector for auditability
        if ns in ("auth", "accounts", "vault", "governance"):
            return self.pg

        # Default path — pgvector
        return self.pg

    # ------------------------------------------------------------------
    # Universal dispatch
    # ------------------------------------------------------------------
    def insert(self, req):
        backend = self.choose(req)
        return backend.insert(req)

    def search(self, req):
        backend = self.choose(req)
        return backend.search(req)

    def delete(self, req):
        backend = self.choose(req)
        return backend.delete(req)
