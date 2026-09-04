# runtime/vector/indexer/eval.py
"""Offline evaluation harness for Qdrant indexer performance.
Measures precision, recall, and other metrics against ground truth.
"""

import json
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from qdrant_client import QdrantClient  # type: ignore[import-not-found]


@dataclass
class EvaluationMetrics:
    """Evaluation metrics for indexer performance."""

    precision: float
    recall: float
    f1_score: float
    mean_reciprocal_rank: float
    query_count: int
    total_relevant: int
    total_retrieved: int


@dataclass
class TestQuery:
    """Test query with ground truth relevant documents."""

    query_text: str
    relevant_event_ids: list[str]
    identity_filter: dict[str, str] | None = None  # For identity-scoped evaluation


def load_test_dataset(dataset_path: str) -> list[TestQuery]:
    """Load test dataset from JSON file."""
    with open(dataset_path) as f:
        data = json.load(f)

    queries = []
    for item in data:
        queries.append(
            TestQuery(
                query_text=item["query"],
                relevant_event_ids=item["relevant_event_ids"],
                identity_filter=item.get("identity_filter"),
            ),
        )
    return queries


def generate_test_dataset(qdrant_client: QdrantClient, collection_name: str, sample_size: int = 100) -> list[TestQuery]:
    """Generate synthetic test dataset from existing collection."""
    # Sample random points from collection
    points = qdrant_client.scroll(
        collection_name=collection_name,
        limit=sample_size,
        with_payload=True,
        with_vectors=False,
    )[0]

    queries = []
    for point in points:
        payload = point.payload

        # Create query from action_type and intent
        query_parts = []
        if "action_type" in payload:
            query_parts.append(payload["action_type"])
        if "intent" in payload:
            query_parts.append(payload["intent"])

        if query_parts:
            query_text = " ".join(query_parts)
            # Ground truth: this point itself + similar points (simplified)
            relevant_ids = [payload["event_id"]]

            queries.append(
                TestQuery(
                    query_text=query_text,
                    relevant_event_ids=relevant_ids,
                    identity_filter={"spiffe_id": payload.get("spiffe_id")},
                ),
            )

    return queries


def evaluate_query(
    qdrant_client: QdrantClient,
    collection_name: str,
    query: TestQuery,
    embedding_model,
    top_k: int = 10,
) -> tuple[list[str], float]:
    """Evaluate single query and return retrieved IDs and query time."""
    start_time = time.time()

    # Generate embedding for query
    query_vector = embedding_model.embed_query(query.query_text)

    # Build filter for identity scoping if specified
    # Import qdrant model helpers lazily to avoid requiring the package on import
    try:
        from qdrant_client.http.models import FieldCondition, Filter, MatchValue  # type: ignore[import-not-found]
    except Exception:
        FieldCondition = None
        Filter = None
        MatchValue = None

    filter_conditions = []
    if query.identity_filter and FieldCondition is not None and MatchValue is not None:
        for field, value in query.identity_filter.items():
            filter_conditions.append(
                FieldCondition(key=field, match=MatchValue(value=value)),
            )

    search_filter = Filter(must=filter_conditions) if filter_conditions and Filter is not None else None

    # Search Qdrant
    results = qdrant_client.search(
        collection_name=collection_name,
        query_vector=query_vector,
        limit=top_k,
        query_filter=search_filter,
    )

    query_time = time.time() - start_time
    retrieved_ids = [hit.payload["event_id"] for hit in results]

    return retrieved_ids, query_time


def calculate_metrics(retrieved_ids: list[str], relevant_ids: list[str]) -> dict[str, float]:
    """Calculate precision, recall, F1 for a single query."""
    retrieved_set = set(retrieved_ids)
    relevant_set = set(relevant_ids)

    true_positives = len(retrieved_set & relevant_set)
    false_positives = len(retrieved_set - relevant_set)
    false_negatives = len(relevant_set - retrieved_set)

    precision = true_positives / (true_positives + false_positives) if (true_positives + false_positives) > 0 else 0.0
    recall = true_positives / (true_positives + false_negatives) if (true_positives + false_negatives) > 0 else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0

    # Mean Reciprocal Rank
    mrr = 0.0
    for i, retrieved_id in enumerate(retrieved_ids):
        if retrieved_id in relevant_set:
            mrr = 1.0 / (i + 1)
            break

    return {
        "precision": precision,
        "recall": recall,
        "f1_score": f1,
        "mrr": mrr,
        "relevant_found": true_positives,
        "total_relevant": len(relevant_set),
        "total_retrieved": len(retrieved_ids),
    }


def run_evaluation(
    qdrant_client: QdrantClient,
    collection_name: str,
    test_queries: list[TestQuery],
    embedding_model,
    top_k: int = 10,
) -> EvaluationMetrics:
    """Run full evaluation suite and return aggregate metrics."""
    all_metrics = []
    total_query_time = 0.0

    for query in test_queries:
        retrieved_ids, query_time = evaluate_query(
            qdrant_client,
            collection_name,
            query,
            embedding_model,
            top_k,
        )
        total_query_time += query_time

        metrics = calculate_metrics(retrieved_ids, query.relevant_event_ids)
        all_metrics.append(metrics)

    # Aggregate metrics
    avg_precision = sum(m["precision"] for m in all_metrics) / len(all_metrics)
    avg_recall = sum(m["recall"] for m in all_metrics) / len(all_metrics)
    avg_f1 = sum(m["f1_score"] for m in all_metrics) / len(all_metrics)
    avg_mrr = sum(m["mrr"] for m in all_metrics) / len(all_metrics)

    total_relevant = int(sum(m["total_relevant"] for m in all_metrics))
    total_retrieved = int(sum(m["total_retrieved"] for m in all_metrics))

    return EvaluationMetrics(
        precision=avg_precision,
        recall=avg_recall,
        f1_score=avg_f1,
        mean_reciprocal_rank=avg_mrr,
        query_count=len(test_queries),
        total_relevant=total_relevant,
        total_retrieved=total_retrieved,
    )


def print_evaluation_report(metrics: EvaluationMetrics, total_time: float):
    """Print formatted evaluation report."""
    print("=== Qdrant Indexer Evaluation Report ===")
    print(f"Queries evaluated: {metrics.query_count}")
    print(f"Total relevant documents: {metrics.total_relevant}")
    print(f"Total retrieved documents: {metrics.total_retrieved}")
    print()
    print(f"Precision: {metrics.precision:.4f}")
    print(f"Recall: {metrics.recall:.4f}")
    print(f"F1 Score: {metrics.f1_score:.4f}")
    print(f"MRR: {metrics.mean_reciprocal_rank:.4f}")
    print()
    print(f"Query Time: {total_time:.2f}s")
    print(f"Queries/sec: {metrics.query_count / total_time:.4f}")
