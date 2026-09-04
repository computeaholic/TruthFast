# ingest/value_plane/config.py
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    pg_dsn: str
    ch_host: str
    ch_port: int
    ch_db: str
    source: str
    batch_size: int


def _require(name: str) -> str:
    val = os.getenv(name)
    if not val:
        raise RuntimeError(f"Required env var {name} is not set or empty")
    return val


def load_config() -> Config:
    return Config(
        pg_dsn=_require("PG_DSN"),
        ch_host=_require("CH_HOST"),
        ch_port=int(_require("CH_PORT")),
        ch_db=_require("CH_DB"),
        source=_require("LEDGER_SOURCE"),
        batch_size=int(os.getenv("BATCH_SIZE", "500")),
    )
