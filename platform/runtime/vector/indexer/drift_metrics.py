# runtime/vector/indexer/drift_metrics.py
"""Recall@K Trend Drift Detection (Soft Signal)
Tracks semantic quality degradation over time using evaluation metrics.
"""

import json
import sys
from pathlib import Path


def load_evaluation_history(eval_dir: str) -> list[dict]:
    """Load all evaluation result files from the evaluation directory.
    Returns list of evaluation results sorted by timestamp.
    """
    eval_files = []
    eval_path = Path(eval_dir)

    if not eval_path.exists():
        return []

    # Find all JSON files in eval directory
    for json_file in eval_path.glob("*.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)

            # Add filename for timestamp sorting
            data["_filename"] = json_file.name
            eval_files.append(data)

        except (OSError, json.JSONDecodeError) as e:
            print(f"Warning: Failed to load {json_file}: {e}")
            continue

    # Sort by filename (assuming timestamp-based naming)
    eval_files.sort(key=lambda x: x.get("_filename", ""), reverse=True)
    return eval_files


def detect_metrics_drift(eval_history: list[dict], threshold: float = 0.10) -> dict:
    """Detect semantic quality drift by comparing recent vs historical metrics.
    threshold: Minimum drop percentage to trigger warning (default 10%).
    """
    if len(eval_history) < 2:
        return {
            "error": "Insufficient evaluation history for drift detection",
            "evaluations_found": len(eval_history),
        }

    # Use most recent as current, second most recent as baseline
    current = eval_history[0]
    baseline = eval_history[1]

    # Extract key metrics
    current_recall = current.get("precision", 0)  # Note: using precision as proxy for recall@k
    baseline_recall = baseline.get("precision", 0)

    current_f1 = current.get("f1_score", 0)
    baseline_f1 = baseline.get("f1_score", 0)

    current_mrr = current.get("mean_reciprocal_rank", 0)
    baseline_mrr = baseline.get("mean_reciprocal_rank", 0)

    # Calculate percentage changes
    recall_change = (current_recall - baseline_recall) / baseline_recall if baseline_recall > 0 else 0
    f1_change = (current_f1 - baseline_f1) / baseline_f1 if baseline_f1 > 0 else 0
    mrr_change = (current_mrr - baseline_mrr) / baseline_mrr if baseline_mrr > 0 else 0

    # Check for significant degradation
    recall_drift = recall_change < -threshold
    f1_drift = f1_change < -threshold
    mrr_drift = mrr_change < -threshold

    drift_detected = recall_drift or f1_drift or mrr_drift

    result = {
        "drift_detected": drift_detected,
        "threshold": threshold,
        "current_eval": current.get("_filename", "latest"),
        "baseline_eval": baseline.get("_filename", "previous"),
        "metrics": {
            "recall": {
                "current": current_recall,
                "baseline": baseline_recall,
                "change_percent": recall_change * 100,
                "drift": recall_drift,
            },
            "f1_score": {
                "current": current_f1,
                "baseline": baseline_f1,
                "change_percent": f1_change * 100,
                "drift": f1_drift,
            },
            "mean_reciprocal_rank": {
                "current": current_mrr,
                "baseline": baseline_mrr,
                "change_percent": mrr_change * 100,
                "drift": mrr_drift,
            },
        },
        "warning": "Semantic quality degradation detected" if drift_detected else None,
        "total_evaluations": len(eval_history),
    }

    return result


def print_metrics_report(analysis: dict):
    """Print human-readable metrics drift report."""
    print("=== Semantic Quality Drift Analysis ===")

    if analysis.get("error"):
        print(f"❌ Error: {analysis['error']}")
        return

    print(f"Evaluations analyzed: {analysis.get('total_evaluations', 0)}")
    print(f"Threshold: {analysis.get('threshold', 0) * 100:.1f}% degradation")
    print(f"Current: {analysis.get('current_eval', 'unknown')}")
    print(f"Baseline: {analysis.get('baseline_eval', 'unknown')}")
    print()

    if analysis.get("drift_detected"):
        print("⚠️  DRIFT DETECTED: Semantic quality degradation")
        print("One or more metrics dropped below threshold:")
        print()
    else:
        print("✅ No significant drift detected")
        print()

    metrics = analysis.get("metrics", {})
    for metric_name, data in metrics.items():
        change_pct = data.get("change_percent", 0)
        drift = data.get("drift", False)
        status = "⚠️ " if drift else "✅"

        print(f"{status} {metric_name}:")
        print(f"      Current: {data.get('current', 0):.4f}")
        print(f"      Baseline: {data.get('baseline', 0):.4f}")
        print(f"      Change: {change_pct:+.2f}%")
        print()

    if analysis.get("warning"):
        print("Recommendation: Investigate embedding model or data quality issues")


def save_metrics_report(analysis: dict, output_path: str):
    """Save metrics analysis to JSON file."""
    # Remove internal fields before saving
    clean_analysis = {k: v for k, v in analysis.items() if not k.startswith("_")}
    for metric in clean_analysis.get("metrics", {}).values():
        if "_filename" in metric:
            del metric["_filename"]

    with open(output_path, "w") as f:
        json.dump(clean_analysis, f, indent=2)


if __name__ == "__main__":
    # Command-line interface for standalone execution
    if len(sys.argv) != 2:
        print("Usage: python drift_metrics.py <eval_directory>")
        sys.exit(1)

    eval_dir = sys.argv[1]

    try:
        history = load_evaluation_history(eval_dir)
        analysis = detect_metrics_drift(history)
        print_metrics_report(analysis)

    except Exception as e:
        print(f"Failed to run metrics analysis: {e}")
        sys.exit(1)
