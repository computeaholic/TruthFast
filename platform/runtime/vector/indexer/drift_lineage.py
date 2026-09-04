# runtime/vector/indexer/drift_lineage.py
"""Embedding Lineage Drift Detection (Hard Signal)
Detects changes in embedding_model_hash and source_schema_hash across collection points.
"""

import json
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from qdrant_client import QdrantClient  # type: ignore[import-not-found]


def detect_lineage_drift(qdrant_client: QdrantClient, collection_name: str) -> dict:
    """Detect embedding lineage drift by analyzing point metadata.
    Returns drift analysis with warnings if multiple lineages detected.
    """
    try:
        # Scroll through all points to collect lineage metadata
        lineages = set()
        total_points = 0

        offset = None
        while True:
            points, next_offset = qdrant_client.scroll(
                collection_name=collection_name,
                limit=1000,
                offset=offset,
                with_payload=True,
                with_vectors=False,
            )

            if not points:
                break

            for point in points:
                payload = point.payload
                # Extract lineage identifiers from point metadata
                embedding_hash = payload.get("embedding_model_hash")
                schema_hash = payload.get("source_schema_hash")

                if embedding_hash and schema_hash:
                    lineages.add((embedding_hash, schema_hash))
                    total_points += 1

            offset = next_offset
            if offset is None:
                break

        # Analyze results
        drift_detected = len(lineages) > 1
        lineage_list = [{"embedding_model_hash": emb, "source_schema_hash": sch} for emb, sch in lineages]

        result = {
            "collection_name": collection_name,
            "total_points_analyzed": total_points,
            "unique_lineages": len(lineages),
            "lineages": lineage_list,
            "drift_detected": drift_detected,
            "warning": "Multiple embedding lineages detected - rebuild recommended" if drift_detected else None,
        }

        return result

    except Exception as e:
        return {
            "error": f"Failed to analyze lineage drift: {e!s}",
            "collection_name": collection_name,
        }


def print_lineage_report(analysis: dict):
    """Print human-readable lineage drift report."""
    print("=== Embedding Lineage Drift Analysis ===")
    print(f"Collection: {analysis.get('collection_name', 'unknown')}")
    print(f"Points analyzed: {analysis.get('total_points_analyzed', 0)}")
    print(f"Unique lineages: {analysis.get('unique_lineages', 0)}")
    print()

    if analysis.get("error"):
        print(f"❌ Error: {analysis['error']}")
        return

    if analysis.get("drift_detected"):
        print("⚠️  DRIFT DETECTED: Multiple embedding lineages found")
        print("This indicates the collection contains vectors from different:")
        print("- Embedding models")
        print("- Source schemas")
        print()
        print("Lineages detected:")
        for i, lineage in enumerate(analysis.get("lineages", []), 1):
            print(f"  {i}. Model: {lineage['embedding_model_hash'][:8]}...")
            print(f"     Schema: {lineage['source_schema_hash'][:8]}...")
        print()
        print("Recommendation: Rebuild collection for consistency")
    else:
        print("✅ No drift detected - all points from single lineage")

    print()


def save_lineage_report(analysis: dict, output_path: str):
    """Save lineage analysis to JSON file."""
    with open(output_path, "w") as f:
        json.dump(analysis, f, indent=2)


if __name__ == "__main__":
    # Command-line interface for standalone execution
    if len(sys.argv) != 4:
        print("Usage: python drift_lineage.py <qdrant_host> <qdrant_port> <collection_name>")
        sys.exit(1)

    host, port_str, collection = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        port = int(port_str)
        client = QdrantClient(host=host, port=port)
        analysis = detect_lineage_drift(client, collection)
        print_lineage_report(analysis)

    except Exception as e:
        print(f"Failed to run lineage analysis: {e}")
        sys.exit(1)
