from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class PgVectorConfig:
    """Configuration for PostgreSQL + pgvector backend."""

    host: str
    port: int
    database: str
    user: str
    password: str

    @classmethod
    def from_env(cls) -> Optional["PgVectorConfig"]:
        """Load configuration from environment variables.

        Returns None if required variables are missing.
        """
        host = os.getenv("PGVECTOR_HOST")
        port_str = os.getenv("PGVECTOR_PORT", "5432")
        database = os.getenv("PGVECTOR_DATABASE")
        user = os.getenv("PGVECTOR_USER")
        password = os.getenv("PGVECTOR_PASSWORD")

        # Check required variables
        if host is None or database is None or user is None or password is None:
            return None

        try:
            port = int(port_str)
        except ValueError:
            raise ValueError(f"Invalid PGVECTOR_PORT: {port_str}") from None

        return cls(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password,
        )


class PgVectorBackend:
    name = "pgvector"

    def __init__(self):
        self._conn = None
        self._config = PgVectorConfig.from_env()

        if self._config is None:
            raise RuntimeError(
                "PgVectorBackend requires configuration via environment variables: "
                "PGVECTOR_HOST, PGVECTOR_DATABASE, PGVECTOR_USER, PGVECTOR_PASSWORD "
                "(PGVECTOR_PORT defaults to 5432)"
            )

    @staticmethod
    def _require_config(config: PgVectorConfig | None) -> PgVectorConfig:
        if config is None:
            raise RuntimeError("MISSING_PREREQ: PgVectorConfig is not initialized")
        return config

    # --------------------------------------------------
    # Lazy connection (psycopg v3)
    # --------------------------------------------------
    def _connect(self):
        if self._conn is not None:
            return

        config = self._require_config(self._config)

        try:
            import psycopg
        except ImportError as e:
            raise RuntimeError("PgVectorBackend requires psycopg v3 (pip install psycopg[c])") from e

        self._conn = psycopg.connect(
            host=config.host,
            port=config.port,
            dbname=config.database,
            user=config.user,
            password=config.password,
        )

    # --------------------------------------------------
    # Example entrypoint
    # --------------------------------------------------
    def upsert(self, *args, **kwargs):
        self._connect()
        # implementation continues…
