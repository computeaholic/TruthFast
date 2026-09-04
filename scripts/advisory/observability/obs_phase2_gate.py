#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import sys


def _to_float(val: str) -> float | None:
    try:
        return float(val)
    except Exception:
        return None


def _to_int(val: str) -> int | None:
    try:
        return int(val)
    except Exception:
        return None


def parse_runtime_artifact(path: str) -> dict:
    lines = open(path, "r", encoding="utf-8").read().splitlines()

    metric_count_delta: float | None = None
    metric_count_baseline_delta: float | None = None
    queries: dict[str, dict] = {}
    post_wait: dict[str, float | None] = {}

    current: str | None = None
    pending_post_wait_query: str | None = None

    for line in lines:
        if line.startswith("metric_count_delta:"):
            metric_count_delta = _to_float(line.split(":", 1)[1].strip())
            continue
        if line.startswith("metric_count_baseline_delta:"):
            metric_count_baseline_delta = _to_float(line.split(":", 1)[1].strip())
            continue

        if line.startswith("## QUERY:"):
            current = line.split(":", 1)[1].strip()
            queries[current] = {}
            continue

        if line.startswith("## POST_WAIT"):
            current = None
            continue

        if current:
            if line.startswith("result_count_after:"):
                queries[current]["result_count_after"] = _to_int(line.split(":", 1)[1].strip())
                continue
            if line.startswith("result_count_before:"):
                queries[current]["result_count_before"] = _to_int(line.split(":", 1)[1].strip())
                continue
            if line.startswith("before:"):
                queries[current]["before"] = _to_float(line.split(":", 1)[1].strip())
                continue
            if line.startswith("after:"):
                queries[current]["after"] = _to_float(line.split(":", 1)[1].strip())
                continue
            if line.startswith("delta:"):
                queries[current]["delta"] = _to_float(line.split(":", 1)[1].strip())
                continue

        if line.startswith("post_wait_query:"):
            pending_post_wait_query = line.split(":", 1)[1].strip()
            continue
        if line.startswith("post_wait_value:") and pending_post_wait_query:
            post_wait[pending_post_wait_query] = _to_float(line.split(":", 1)[1].strip())
            pending_post_wait_query = None
            continue

    return {
        "metric_count_delta": metric_count_delta,
        "metric_count_baseline_delta": metric_count_baseline_delta,
        "queries": queries,
        "post_wait": post_wait,
    }


def parse_alert_timing_matrix(path: str) -> dict:
    lines = open(path, "r", encoding="utf-8").read().splitlines()
    out: dict[str, str] = {}
    for line in lines:
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip()] = v.strip()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--alert-matrix", required=True)
    ap.add_argument("--flags", default="")
    args = ap.parse_args()

    # Gate on deterministic signals that should be present and mutable for a
    # single end-to-end request.
    #
    # Notes:
    # - Gauges (eg. queue depth) often have 0 delta for successful steady-state traffic.
    # - Governance CCID-bound metrics require valid AAS/Decision artifacts; they are
    #   not guaranteed in minimal Phase 2 clusters.
    required_metrics = [
        "smp_dispatch_total",
        "smp_dispatch_latency_ms_count",
        "ledger_write_operations_total",
        "identity_coverage_ratio",
    ]

    rt = parse_runtime_artifact(args.artifact)
    errors: list[str] = []

    mcd = rt["metric_count_delta"]
    mcb = rt["metric_count_baseline_delta"]

    if mcd is None:
        errors.append("metric_count_delta missing")
    if mcb is None:
        errors.append("metric_count_baseline_delta missing")

    if mcd is not None and mcd > 5:
        errors.append("metric count delta exceeds +5")
    if mcb is not None and mcb > 5:
        errors.append("metric count baseline delta exceeds +5")

    q = rt["queries"]
    for metric in required_metrics:
        if metric not in q:
            errors.append(f"missing query section: {metric}")
            continue
        result_count = q[metric].get("result_count_after")
        if result_count is None or result_count == 0:
            errors.append(f"empty query result for {metric}")
        delta = q[metric].get("delta")
        if metric == "identity_coverage_ratio":
            before = q[metric].get("before")
            after = q[metric].get("after")
            if before is not None and after is not None and after < before:
                errors.append("identity_coverage_ratio dropped")
            if after is None or after <= 0:
                errors.append("identity_coverage_ratio not positive")
        else:
            if delta is None or delta <= 0:
                errors.append(f"no positive delta for {metric}")

    post_wait = rt["post_wait"]

    queue_depth = post_wait.get("smp_queue_depth")
    if queue_depth is None:
        errors.append("post_wait smp_queue_depth missing")
    elif queue_depth != 0:
        errors.append("smp_queue_depth did not return to 0")

    in_flight = post_wait.get("smp_in_flight")
    if in_flight is None:
        errors.append("post_wait smp_in_flight missing")
    elif in_flight != 0:
        errors.append("smp_in_flight did not return to 0")

    refusals = post_wait.get("smp_refusals_total")
    if refusals is None:
        errors.append("post_wait smp_refusals_total missing")
    elif refusals != 0:
        errors.append("smp_refusals_total non-zero after wait")

    alerts = post_wait.get('count(ALERTS{alertstate="firing"})')
    if alerts is None:
        errors.append("post_wait alert count missing")
    elif alerts != 0:
        errors.append("alerts firing after wait")

    # If inject-failure mode was requested, enforce that an alert timing matrix exists and meets SLA.
    flags = args.flags or ""
    if "--inject-failure=" in flags:
        if not os.path.exists(args.alert_matrix):
            errors.append("alert timing matrix missing")
        else:
            am = parse_alert_timing_matrix(args.alert_matrix)
            det = _to_float(am.get("detection_latency_seconds", ""))
            rec = _to_float(am.get("recovery_time_seconds", ""))
            unexpected = am.get("unexpected_alerts", "")

            if det is None:
                errors.append("alert detection latency missing")
            elif det > 60:
                errors.append("alert detection latency > 60s")

            if rec is None:
                errors.append("alert recovery time missing")

            if unexpected and unexpected != "none":
                errors.append("unexpected alerts fired")

    if errors:
        sys.stderr.write("OBSERVABILITY VALIDATION FAILED:\n")
        for err in errors:
            sys.stderr.write(f"- {err}\n")
        return 1

    sys.stdout.write("OBSERVABILITY VALIDATION PASSED\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
