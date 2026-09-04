# runtime/vector/indexer/evaluate.py
"""Offline evaluation runner for Qdrant indexer.
Loads test dataset and measures performance metrics.
"""

import os
import sys
import time

from runtime.vector.indexer.config import load_config
from runtime.vector.indexer.embed import create_embedding_model
from runtime.vector.indexer.eval import (
    generate_test_dataset,
    load_test_dataset,
    print_evaluation_report,
    run_evaluation,
)

# qdrant_client is imported lazily inside main() so this module can be imported in environments
# without the package installed (smoke-test friendliness).


def main():
    """Run offline evaluation of Qdrant indexer."""
    try:
        # Load configuration
        cfg = load_config()
        print(f"Starting evaluation for collection: {cfg.vector_collection}")

        # Connect to Qdrant (import lazily to avoid import-time failures)
        try:
            from qdrant_client import QdrantClient  # type: ignore[import-not-found]
        except Exception as err:
            raise RuntimeError("qdrant_client is required for evaluation but is not available") from err

        qdrant = QdrantClient(host=cfg.qdrant_host, port=cfg.qdrant_port)

        # Create embedding model
        model = create_embedding_model(cfg.vector_model)
        print(f"Using embedding model: {model.model_name}")

        # Determine collection name (handle identity scoping)
        collection_name = cfg.vector_collection
        if cfg.identity_scoping_enabled:
            collection_name = f"{collection_name}_scoped"

        # Load or generate test dataset
        dataset_path = os.getenv("TEST_DATASET_PATH")
        if dataset_path and os.path.exists(dataset_path):
            print(f"Loading test dataset from: {dataset_path}")
            test_queries = load_test_dataset(dataset_path)
        else:
            print("Generating synthetic test dataset from collection")
            test_queries = generate_test_dataset(qdrant, collection_name, sample_size=50)

        print(f"Loaded/generated {len(test_queries)} test queries")

        # Run evaluation with timing
        print("Running evaluation...")
        start_time = time.time()
        metrics = run_evaluation(qdrant, collection_name, test_queries, model, top_k=10)
        duration_seconds = time.time() - start_time

        # Print report with actual timing
        print_evaluation_report(metrics, duration_seconds)

        # Save results to file if requested
        output_path = os.getenv("EVALUATION_OUTPUT_PATH")
        if output_path:
            import json

            result = {
                "precision": metrics.precision,
                "recall": metrics.recall,
                "f1_score": metrics.f1_score,
                "mean_reciprocal_rank": metrics.mean_reciprocal_rank,
                "query_count": metrics.query_count,
                "total_relevant": metrics.total_relevant,
                "total_retrieved": metrics.total_retrieved,
            }
            with open(output_path, "w") as f:
                json.dump(result, f, indent=2)
            print(f"Results saved to: {output_path}")

    except Exception as e:
        print(f"Evaluation failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
