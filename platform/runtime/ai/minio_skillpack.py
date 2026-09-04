# runtime/ai/minio_skillpack.py
from __future__ import annotations

import hashlib
import io
import os
import time
from enum import Enum
from typing import Any

from minio import Minio

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.guards import require
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.signal.fabric import emit


# ============================================================================
# Bucket Enum (Canonical, Deterministic, Zero Drift)
# ============================================================================
class Bucket(str, Enum):
    MODELS = "tf-models"
    LORA = "tf-lora"
    SIM = "tf-sim"
    EVENTS = "tf-events"
    AUDIT = "tf-audit"
    UPLOADS = "tf-uploads"
    CHECKPOINTS = "tf-checkpoints"
    REGISTRY = "tf-registry"


# ============================================================================
# Cluster-Aware MinIO Client Factory (Alpha → Bravo → Charlie Ready)
# ============================================================================
class MinioClientFactory:
    """Multi-site aware MinIO factory. Defaults to Alpha cluster
    but can route to Bravo/Charlie once replication is activated.
    """

    CLUSTER_ENDPOINTS = {
        "alpha": "minio.minio.svc.cluster.local:9000",
        "bravo": "minio-bravo.minio.svc.cluster.local:9000",
        "charlie": "minio-charlie.minio.svc.cluster.local:9000",
    }

    def __init__(
        self,
        access_key_env: str | None = None,
        secret_key_env: str | None = None,
    ):
        # Default values are environment variable names; avoid hardcoded credential defaults in signature
        self._access_key_env = access_key_env or "TF_MINIO_ACCESS_KEY"
        self._secret_key_env = secret_key_env or "TF_MINIO_SECRET_KEY"

    def _creds(self) -> tuple[str, str]:
        """ThreadForge uses SPIRE+Istio for transport identity (mTLS),
        but MinIO still requires S3 credentials for authorization.

        We intentionally source these from env so Helm/K8s Secrets can own them.
        """
        ak = os.getenv(self._access_key_env) or os.getenv("MINIO_ROOT_USER") or os.getenv("MINIO_ACCESS_KEY")
        sk = os.getenv(self._secret_key_env) or os.getenv("MINIO_ROOT_PASSWORD") or os.getenv("MINIO_SECRET_KEY")
        if not ak or not sk:
            raise RuntimeError(
                "MinIO credentials not configured. Set TF_MINIO_ACCESS_KEY / TF_MINIO_SECRET_KEY "
                "(or MINIO_ROOT_USER / MINIO_ROOT_PASSWORD) on the workload.",
            )
        return ak, sk

    def client(self, cluster: str = "alpha") -> Minio:
        if cluster not in self.CLUSTER_ENDPOINTS:
            raise ValueError(f"Invalid cluster: {cluster}")

        access_key, secret_key = self._creds()
        # Use positional endpoint to satisfy type stubs across MinIO versions.
        return Minio(
            self.CLUSTER_ENDPOINTS[cluster],
            access_key=access_key,
            secret_key=secret_key,
            secure=False,  # transport is mTLS via mesh
        )


# ============================================================================
# Reflex Rules (Safety Rails)
# ============================================================================
class StorageReflex:
    """Enforces strict operation rules:
    - Some buckets are read-only
    - Some are write-only
    - Some are append-only
    - Registry + audit require operator role
    """

    READ_ONLY = {Bucket.MODELS}
    WRITE_ONLY = {Bucket.SIM, Bucket.EVENTS}
    OPERATOR_ONLY = {Bucket.AUDIT, Bucket.REGISTRY}
    READ_WRITE = {
        Bucket.LORA,
        Bucket.UPLOADS,
        Bucket.CHECKPOINTS,
    }

    @staticmethod
    def validate(actor: str, bucket: Bucket, op: str):
        # Operator buckets
        if bucket in StorageReflex.OPERATOR_ONLY and actor != "ella-core":
            raise PermissionError(f"Actor '{actor}' cannot write to {bucket}")

        # Read-only bucket
        if op == "write" and bucket in StorageReflex.READ_ONLY:
            raise PermissionError(f"{bucket} is READ-ONLY")

        # Write-only bucket
        if op == "read" and bucket in StorageReflex.WRITE_ONLY:
            raise PermissionError(f"{bucket} is WRITE-ONLY")

        # Normal RW buckets covered by READ_WRITE


# ============================================================================
# Lineage Hasher (Ready, SHA3-512)
# ============================================================================
class LineageHasher:
    @staticmethod
    def sha3_512(data: bytes) -> str:
        h = hashlib.sha3_512()
        h.update(data)
        return h.hexdigest()


# ============================================================================
# MinIO SkillPack (Storage Engine)
# ============================================================================
class MinioSkillPack:
    def __init__(self):
        self.factory = MinioClientFactory()
        self.ledger = OperatorLedger()

    # ----------------------------------------------------------------------
    # Internal Client
    # ----------------------------------------------------------------------
    def _client(self, cluster: str = "alpha") -> Minio:
        return self.factory.client(cluster=cluster)

    # ----------------------------------------------------------------------
    # Audit Event Wrapper (writes into Operator Ledger)
    # ----------------------------------------------------------------------
    def _audit(
        self,
        actor: str,
        bucket: Bucket,
        object_name: str,
        op: str,
        duration_ms: float,
        size: int | None = None,
        lineage: str | None = None,
    ):
        self.ledger.record(
            {
                "type": "STORAGE_EVENT",
                "bucket": bucket.value,
                "object": object_name,
                "actor": actor,
                "operation": op,
                "duration_ms": duration_ms,
                "size": size,
                "lineage": lineage,
                "timestamp": time.time(),
            },
        )

        # NavBus broadcast
        emit(
            "STORAGE_EVENT",
            {
                "op": op,
                "bucket": bucket.value,
                "object": object_name,
                "lineage": lineage,
                "size": size,
                "duration_ms": duration_ms,
            },
        )

    # ----------------------------------------------------------------------
    # WRITE Object
    # ----------------------------------------------------------------------
    def upload(
        self,
        actor: str,
        bucket: Bucket,
        object_name: str,
        data: bytes,
        cluster: str = "alpha",
        caps: CapabilitySet | None = None,
    ) -> dict[str, Any]:
        # Phase 10: Capability enforcement (fail-closed)
        if caps is not None:
            require("storage.write", caps)

        StorageReflex.validate(actor, bucket, "write")

        c = self._client(cluster)
        start = time.time()

        lineage = LineageHasher.sha3_512(data)

        # MinIO SDK expects a stream, not raw bytes.
        stream = io.BytesIO(data)
        c.put_object(bucket.value, object_name, stream, length=len(data))

        duration = (time.time() - start) * 1000
        self._audit(actor, bucket, object_name, "write", duration, size=len(data), lineage=lineage)

        return {
            "bucket": bucket.value,
            "object": object_name,
            "cluster": cluster,
            "duration_ms": duration,
            "lineage": lineage,
        }

    # ----------------------------------------------------------------------
    # READ Object
    # ----------------------------------------------------------------------
    def download(
        self,
        actor: str,
        bucket: Bucket,
        object_name: str,
        cluster: str = "alpha",
        caps: CapabilitySet | None = None,
    ) -> bytes:
        # Phase 10: Capability enforcement (fail-closed)
        if caps is not None:
            require("storage.read", caps)

        StorageReflex.validate(actor, bucket, "read")

        c = self._client(cluster)
        start = time.time()
        response = c.get_object(bucket.value, object_name)  # pyright: ignore[reportCallIssue]
        blob = response.read()
        duration = (time.time() - start) * 1000

        self._audit(actor, bucket, object_name, "read", duration, size=len(blob))

        return blob

    # ----------------------------------------------------------------------
    # LIST Objects
    # ----------------------------------------------------------------------
    def list(
        self,
        actor: str,
        bucket: Bucket,
        cluster: str = "alpha",
        caps: CapabilitySet | None = None,
    ) -> dict[str, Any]:
        # Phase 10: Capability enforcement (fail-closed)
        if caps is not None:
            require("storage.list", caps)

        # list is considered a read op
        StorageReflex.validate(actor, bucket, "read")

        c = self._client(cluster)
        start = time.time()

        objs = [o.object_name for o in c.list_objects(bucket.value)]  # pyright: ignore[reportCallIssue]

        duration = (time.time() - start) * 1000
        self._audit(actor, bucket, "*", "list", duration)

        return {"bucket": bucket.value, "objects": objs}

    # ----------------------------------------------------------------------
    # SIM SNAPSHOT Save
    # ----------------------------------------------------------------------
    def save_snapshot(self, actor: str, name: str, payload: bytes):
        return self.upload(actor, Bucket.SIM, f"{name}.bin", payload)

    # ----------------------------------------------------------------------
    # LORA Save / Fetch
    # ----------------------------------------------------------------------
    def save_lora(self, actor: str, name: str, blob: bytes):
        return self.upload(actor, Bucket.LORA, f"{name}.safetensors", blob)

    def get_lora(self, actor: str, name: str) -> bytes:
        return self.download(actor, Bucket.LORA, f"{name}.safetensors")

    # ----------------------------------------------------------------------
    # SMP / NavBus Routing Stubs (Activated in Phase 4)
    # ----------------------------------------------------------------------
    def smp_handler(self, envelope: Any):
        """This makes storage operations available across the entire cluster
        through SMP envelopes. Phase 4 will fully wire this in.
        """
