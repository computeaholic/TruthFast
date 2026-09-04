# runtime/vector/indexer/drift_check.py
"""Semantic Drift Detection Orchestrator
Combines lineage and metrics drift detection for comprehensive analysis.
"""

import os
import sys

from runtime.vector.indexer.drift_lineage import detect_lineage_drift, print_lineage_report
from runtime.vector.indexer.drift_metrics import detect_metrics_drift, load_evaluation_history, print_metrics_report

# Note: qdrant_client is an optional runtime dependency. Import it lazily inside
# run_drift_check so this module can be imported in environments lacking qdrant.


def run_drift_check(qdrant_host: str, qdrant_port: int, collection_name: str, eval_dir: str):
    """Run comprehensive drift detection analysis.
    Combines lineage drift (hard signal) and metrics drift (soft signal).
    """
    print("🔍 ThreadForge Semantic Drift Detection")
    print("=" * 50)
    print()

    try:
        from qdrant_client import QdrantClient  # type: ignore[import-not-found]
    except Exception as err:
        raise RuntimeError("qdrant_client is required to run drift checks") from err

    client = QdrantClient(host=qdrant_host, port=qdrant_port)

    # 1. Check Embedding Lineage Drift (Hard Signal)
    print("1️⃣ Analyzing Embedding Lineage Drift...")
    lineage_analysis = detect_lineage_drift(client, collection_name)
    print_lineage_report(lineage_analysis)

    # 2. Check Metrics Trend Drift (Soft Signal)
    print("2️⃣ Analyzing Semantic Quality Trends...")
    eval_history = load_evaluation_history(eval_dir)
    metrics_analysis = detect_metrics_drift(eval_history)
    print_metrics_report(metrics_analysis)

    # 3. Overall Assessment
    print("3️⃣ Overall Drift Assessment")
    print("-" * 30)

    lineage_drift = lineage_analysis.get("drift_detected", False)
    metrics_drift = metrics_analysis.get("drift_detected", False)

    if lineage_drift or metrics_drift:
        print("⚠️  DRIFT DETECTED")
        print()
        print("Issues found:")

        if lineage_drift:
            print("• Multiple embedding lineages (rebuild recommended)")
        if metrics_drift:
            print("• Semantic quality degradation detected")

        print()
        print("Actions:")
        print("• Review embedding model consistency")
        print("• Check data source schema stability")
        print("• Consider rebuilding collection if lineage drift")
        print("• Investigate data quality if metrics degraded")

    else:
        print("✅ NO DRIFT DETECTED")
        print("Collection appears consistent and stable")

    print()
    print("Note: Drift detection is advisory only")
    print("Qdrant remains non-authoritative and rebuildable")

    # Return combined results
    return {
        "lineage_analysis": lineage_analysis,
        "metrics_analysis": metrics_analysis,
        "overall_drift": lineage_drift or metrics_drift,
    }


def main():
    """Command-line interface for drift detection."""
    # Get configuration from environment or command line
    qdrant_host = os.getenv("QDRANT_HOST", "localhost")
    qdrant_port = int(os.getenv("QDRANT_PORT", "6333"))
    collection_name = os.getenv("VECTOR_COLLECTION", "operator_semantic")
    eval_dir = os.getenv("EVAL_DIR", "out/qdrant/eval")

    # Allow override via command line args
    if len(sys.argv) >= 2:
        qdrant_host = sys.argv[1]
    if len(sys.argv) >= 3:
        qdrant_port = int(sys.argv[2])
    if len(sys.argv) >= 4:
        collection_name = sys.argv[3]
    if len(sys.argv) >= 5:
        eval_dir = sys.argv[4]

    try:
        results = run_drift_check(qdrant_host, qdrant_port, collection_name, eval_dir)

        # Exit with code indicating drift detection
        sys.exit(1 if results["overall_drift"] else 0)

    except Exception as e:
        print(f"❌ Drift check failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
