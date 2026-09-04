# runtime/vector/indexer/config.py
"""Configuration for Qdrant indexer.
Fail-fast configuration loading with required environment variables.
"""

import hashlib
import os
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any


@dataclass
class IndexerConfig:
    """Configuration for the Qdrant vector indexer."""

    # Database connections
    pg_dsn: str
    ch_host: str
    ch_port: int

    # Qdrant connection
    qdrant_host: str
    qdrant_port: int

    # Vector configuration
    vector_collection: str
    vector_model: str

    # Collection versioning metadata
    collection_version: str
    embedding_model_hash: str
    source_schema_hash: str
    build_time_utc: str

    # Identity scoping
    identity_scoping_enabled: bool = False

    # Ingestion parameters
    batch_size: int = 100
    source: str = "operator"  # "operator" or "value"


def load_config() -> IndexerConfig:
    """Load configuration from environment variables. Fail fast if required vars missing."""
    # Required environment variables
    required_vars = {
        "PG_DSN": "pg_dsn",
        "CH_HOST": "ch_host",
        "CH_PORT": "ch_port",
        "QDRANT_HOST": "qdrant_host",
        "QDRANT_PORT": "qdrant_port",
        "VECTOR_COLLECTION": "vector_collection",
        "VECTOR_MODEL": "vector_model",
    }

    config_dict: dict[str, Any] = {}
    missing_vars = []

    for env_var, config_key in required_vars.items():
        value = os.getenv(env_var)
        if value is None:
            missing_vars.append(env_var)
            continue

        # Type conversion
        if config_key in ["ch_port", "qdrant_port"]:
            try:
                config_dict[config_key] = int(value)
            except ValueError as err:
                raise ValueError(f"Environment variable {env_var} must be an integer") from err
        else:
            config_dict[config_key] = value

    if missing_vars:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing_vars)}")

    # Optional variables with defaults
    config_dict["batch_size"] = int(os.getenv("BATCH_SIZE", "100"))
    config_dict["source"] = os.getenv("SOURCE", "operator")
    config_dict["identity_scoping_enabled"] = os.getenv("IDENTITY_SCOPING_ENABLED", "false").lower() == "true"

    # Validate source
    if config_dict["source"] not in ["operator", "value"]:
        raise ValueError("SOURCE must be 'operator' or 'value'")

    # Generate collection versioning metadata
    build_time = datetime.now(UTC)
    config_dict["collection_version"] = build_time.isoformat()
    config_dict["embedding_model_hash"] = hashlib.sha256(
        config_dict["vector_model"].encode(),
    ).hexdigest()
    config_dict["source_schema_hash"] = generate_source_schema_hash(config_dict["source"])
    config_dict["build_time_utc"] = build_time.isoformat()

    return IndexerConfig(**config_dict)


def generate_source_schema_hash(source: str) -> str:
    """Generate hash of the allowed fields schema for the given source."""
    if source == "operator":
        # Explicit allow-list from operator_ledger_v2
        schema_fields = [
            "action_type",
            "action_scope",
            "intent",
            "target_type",
            "target_identifier",
            "result",
            "status",
        ]
    elif source == "value":
        # Explicit allow-list from value_plane.cost_model
        schema_fields = [
            "compute_units",
            "policy_units",
            "total_cost_units",
            "source_ledger",
        ]
    else:
        raise ValueError(f"Unknown source: {source}")

    schema_str = "|".join(sorted(schema_fields))
    return hashlib.sha256(schema_str.encode()).hexdigest()
