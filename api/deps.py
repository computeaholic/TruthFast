# =====================================================================
# ThreadForge — Legacy API Dependencies (compatibility only)
# Path: api/deps.py
# =====================================================================

from typing import Annotated

from fastapi import Depends

from runtime.ai.minio_skillpack import MinioSkillPack
from runtime.ai.traffic import TrafficRouter
from runtime.ai.vector_executor import OperatorVectorExecutor
from runtime.api.identity_deps import extract_identity_from_proxy_headers
from runtime.core.signal_fabric import SignalFabric
from runtime.identity.context import IdentityContext
from runtime.operator_logic import decide_route

# =====================================================================
# Identity Enforcement
# =====================================================================


def extract_spiffe_identity(
    identity: Annotated[IdentityContext, Depends(extract_identity_from_proxy_headers)],
) -> str:
    """Compatibility dependency backed by the canonical proxy identity contract.

    This function intentionally does not accept ``x-threadforge-spiffe-id`` or
    any other caller-asserted identity header. FastAPI resolves ``identity`` via
    ``extract_identity_from_proxy_headers``, which requires exactly one SPIFFE
    URI from the trusted proxy-produced XFCC contract.

    The root ``api/`` package is not an independent runtime authority surface;
    the canonical application is ``runtime.api.app:app``.
    """
    return identity.spiffe_id


# =====================================================================
# Singleton Dependencies (Backend Resources)
# =====================================================================

# Singleton fabric for compatibility callers that still import these helpers.
FABRIC = SignalFabric()

# Traffic router (storage + routing logic)
TRAFFIC = TrafficRouter(FABRIC)

# Storage backend (MinIO via STS)
STORAGE = MinioSkillPack()

# Vector executor (vLLM / pgvector / qdrant)
VECTOR_EXECUTOR = OperatorVectorExecutor(fabric=FABRIC)

# SMP router (operator_logic decides backend)
DECIDE = decide_route
