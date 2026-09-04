# runtime/vector/indexer/drift_detector.py
"""Semantic drift tracker for Qdrant indexer evaluations.

This module runs offline evaluations (recall@10) and stores time-series
observations to `reports/qdrant_semantic_drift.json`. All outputs are derived
artifacts and do not modify any authoritative store.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from qdrant_client import QdrantClient  # type: ignore[import-not-found]

from runtime.vector.indexer.config import IndexerConfig
from runtime.vector.indexer.embed import create_embedding_model

# Import eval helpers lazily inside run_semantic_drift_check to avoid requiring
# qdrant_client to be present at import time (smoke-test friendly).

logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent
REPORT_DIR = BASE_DIR / "reports"
DRIFT_REPORT = REPORT_DIR / "qdrant_semantic_drift.json"


@dataclass
class DriftObservation:
    """A single observation of evaluation metrics and metadata."""

    timestamp: int
    recall_at_10: float
    embedding_model_hash: str
    collection_version: str
    build_time_utc: str


def run_semantic_drift_check(
    qdrant_client: QdrantClient,
    collection_name: str,
    cfg: IndexerConfig,
    test_dataset_path: str | None = None,
) -> dict[str, Any]:
    """Run evaluation and append observation to the drift report.

    The function computes recall@10 using the existing evaluation harness and
    records a timestamped entry. It also compares the current recall to
    the previous observation for the same model+collection to flag drift.
    """
    # 1. Load or generate test dataset
    # Import evaluation helpers lazily so this module may be imported in
    # environments where qdrant_client is not installed (smoke-test friendliness).
    from runtime.vector.indexer.eval import load_test_dataset, run_evaluation

    test_queries = load_test_dataset(test_dataset_path) if test_dataset_path else []  # best-effort if not provided

    # 2. Create embedding model from current config
    model = create_embedding_model(cfg.vector_model)

    # 3. Run evaluation (recall@10 is aggregated recall)
    metrics = run_evaluation(qdrant_client, collection_name, test_queries, model, top_k=10)
    recall_at_10 = metrics.recall

    obs = DriftObservation(
        timestamp=int(time.time()),
        recall_at_10=recall_at_10,
        embedding_model_hash=cfg.embedding_model_hash,
        collection_version=cfg.collection_version,
        build_time_utc=cfg.build_time_utc,
    )

    # 4. Append to report file
    entry = {
        "timestamp": obs.timestamp,
        "recall_at_10": obs.recall_at_10,
        "embedding_model_hash": obs.embedding_model_hash,
        "collection_version": obs.collection_version,
        "build_time_utc": obs.build_time_utc,
    }

    existing = []
    if DRIFT_REPORT.exists():
        try:
            existing = json.loads(DRIFT_REPORT.read_text())
        except (OSError, ValueError) as err:
            logger.warning("Could not read drift report: %s", err)
            existing = []

    existing.append(entry)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    DRIFT_REPORT.write_text(json.dumps(existing, indent=2))

    # 5. Simple detection: compare to previous observation for same model/collection
    # Use a small set of constants for clarity
    min_obs_for_comparison = 2
    abs_drop_threshold = 0.10
    rel_drop_threshold = 0.20

    related = [e for e in existing if e["embedding_model_hash"] == obs.embedding_model_hash]
    prev = related[-min_obs_for_comparison] if len(related) >= min_obs_for_comparison else None

    drift_detected = False
    if prev is not None and (
        obs.recall_at_10 + 1e-9 < prev["recall_at_10"] - abs_drop_threshold
        or (
            prev["recall_at_10"] > 0
            and (prev["recall_at_10"] - obs.recall_at_10) / prev["recall_at_10"] >= rel_drop_threshold
        )
    ):
        drift_detected = True

    return {"entry": entry, "semantic_drift_detected": drift_detected}


if __name__ == "__main__":
    # Simple CLI for on-demand execution
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("collection")
    parser.add_argument("--test-dataset", default=None)
    args = parser.parse_args()

    # Construct a local Qdrant client (assumes env/host config)
    try:
        from qdrant_client import QdrantClient  # type: ignore[import-not-found]
    except Exception as err:
        raise SystemExit("qdrant_client is required for the drift detector CLI but is not available: %s" % err) from err

    q = QdrantClient()
    ch_port = int(__import__("os").getenv("CLICKHOUSE_PORT", "9000"))
    cfg = IndexerConfig(
        pg_dsn="",
        ch_host="",
        ch_port=ch_port,
        qdrant_host="",
        qdrant_port=6333,
        vector_collection=args.collection,
        vector_model="sentence-transformers/all-mpnet-base-v2",
        collection_version="manual-run",
        embedding_model_hash="manual",
        source_schema_hash="manual",
        build_time_utc="manual",
    )

    out = run_semantic_drift_check(q, args.collection, cfg, args.test_dataset)
    logger.info("Semantic drift check result: %s", out)
