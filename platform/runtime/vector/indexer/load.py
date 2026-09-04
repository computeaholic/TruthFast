# runtime/vector/indexer/load.py
"""Load vectors into Qdrant with idempotent inserts.
Uses event_id as primary key for deduplication.
"""

import uuid
from typing import Any


def create_collection_if_not_exists(
    qdrant_client,
    collection_name: str,
    vector_size: int,
    version_metadata: dict[str, str],
    identity_scoping_enabled: bool = False,
):
    """Create Qdrant collection if it doesn't exist with versioning metadata."""
    # When identity scoping is enabled, use single collection for all identities
    if identity_scoping_enabled:
        collection_name = f"{collection_name}_scoped"

    try:
        # Check if collection exists
        collections = qdrant_client.get_collections()
        collection_names = [c.name for c in collections.collections]

        if collection_name not in collection_names:
            qdrant_client.create_collection(
                collection_name=collection_name,
                vectors_config={
                    "": {  # Default vector config
                        "size": vector_size,
                        "distance": "Cosine",
                    },
                },
                # Store versioning metadata at collection level
                metadata=version_metadata,
            )
    except Exception as e:
        raise RuntimeError(f"Failed to create/verify collection {collection_name}: {e}") from e


def insert_vectors(
    qdrant_client,
    collection_name: str,
    records: list[dict[str, Any]],
    version_metadata: dict[str, str],
    identity_scoping_enabled: bool = False,
):
    """Insert vectors into Qdrant.
    Idempotent: uses event_id as point ID.
    Includes versioning metadata in each point for forensic reconstruction.
    """
    # When identity scoping is enabled, use single collection for all identities
    if identity_scoping_enabled:
        collection_name = f"{collection_name}_scoped"
    if not records:
        return

    # Enforce identity presence when identity scoping is enabled — Tier-0 invariant
    if identity_scoping_enabled:
        for rec in records:
            if not rec.get("spiffe_id"):
                raise ValueError("identity_scoping enabled but record missing spiffe_id")

    points = []
    for record in records:
        # Use event_id as deterministic point ID for idempotence
        point_id = uuid.uuid5(uuid.NAMESPACE_DNS, record["event_id"])

        # Required metadata for identity traceability + versioning
        payload = {
            "event_id": record["event_id"],
            "spiffe_id": record["spiffe_id"],
            "identity_class": record["identity_class"],
            "source_ledger": record["source"],
            "created_at": record["created_at"],
            "model_name": record["model_name"],
            # Versioning metadata repeated per-point for forensic reconstruction
            "collection_version": version_metadata["collection_version"],
            "embedding_model_hash": version_metadata["embedding_model_hash"],
            "source_schema_hash": version_metadata["source_schema_hash"],
            "build_time_utc": version_metadata["build_time_utc"],
        }

        points.append(
            {
                "id": str(point_id),
                "vector": record["vector"],
                "payload": payload,
            },
        )

    # Batch upsert - will update existing points with same ID
    qdrant_client.upsert(
        collection_name=collection_name,
        points=points,
    )
