"""Operator-AI Arbitration Logic
Decides final search result from multi-engine fan-out.
Path: operator/hooks/arbitration.py
"""


def arbitration_hook(results):
    """Results = list of dicts returned by agents."""
    best = None
    best_score = -999

    for r in results:
        if not r:
            continue
        for item in r.get("matches", []):
            score = item.get("score", 0)
            if score > best_score:
                best = item
                best_score = score

    return {"best_match": best, "score": best_score, "engine": "Operator-AI Arbitration v1"}
