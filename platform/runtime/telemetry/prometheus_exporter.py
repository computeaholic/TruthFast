from __future__ import annotations

import json
from pathlib import Path
import time
from typing import Any

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, generate_latest

CONTENT_TYPE_LATEST = "text/plain; version=0.0.4; charset=utf-8"


_REGISTRY: CollectorRegistry | None = None
METRICS: dict[str, Any] = {}


def registry() -> CollectorRegistry:
    global _REGISTRY
    if _REGISTRY is None:
        _REGISTRY = CollectorRegistry()
        _init_metrics(_REGISTRY)
        # Bind identity-plane metrics to the same registry so they appear on /metrics
        try:
            from runtime.identity import metrics as identity_metrics

            identity_metrics.reset_metrics(_REGISTRY)
        except Exception:  # nosec B110: Intentional - metrics are best-effort observability
            # Do not break exporter on import errors; gracefully degrade if identity metrics unavailable
            pass

        # Load additional metric exporters (Phase 8 operator action exporter)
        try:
            # Importing this module registers event subscribers that update the operator action metrics
            import runtime.actuator.operator_action_exporter  # noqa: F401
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "operator_action_exporter import", e
            )  # nosec B110: Optional exporter import failure is best-effort and must not stop exporter initialization
    return _REGISTRY


def _init_metrics(reg: CollectorRegistry) -> None:
    METRICS["smp_queue_depth"] = Gauge(
        "smp_queue_depth",
        "Current SMP queue depth",
        ["priority"],
        registry=reg,
    )
    METRICS["smp_queue_oldest_age_seconds"] = Gauge(
        "smp_queue_oldest_age_seconds",
        "Oldest message age per priority",
        ["priority"],
        registry=reg,
    )
    METRICS["smp_in_flight"] = Gauge(
        "smp_in_flight",
        "Number of in-flight SMP envelopes",
        registry=reg,
    )
    METRICS["smp_dispatch_total"] = Counter(
        "smp_dispatch_total",
        "SMP dispatch decisions",
        ["priority", "status"],
        registry=reg,
    )
    METRICS["smp_dispatch_latency_ms"] = Histogram(
        "smp_dispatch_latency_ms",
        "SMP dispatch latency (ms)",
        ["priority"],
        registry=reg,
    )
    METRICS["smp_refusals_total"] = Counter(
        "smp_refusals_total",
        "SMP refusals",
        ["priority", "reason"],
        registry=reg,
    )
    METRICS["ledger_ingest_lag_seconds"] = Gauge(
        "ledger_ingest_lag_seconds",
        "Seconds between now and latest ledger event",
        registry=reg,
    )
    METRICS["ledger_write_operations_total"] = Counter(
        "ledger_write_operations_total",
        "Total ledger write operations",
        registry=reg,
    )
    METRICS["identity_coverage_ratio"] = Gauge(
        "identity_coverage_ratio",
        "Ratio of events with valid SPIFFE IDs to total events",
        registry=reg,
    )

    METRICS["authority_authoritative"] = Gauge(
        "authority_authoritative",
        "Runtime authority state (1 = AUTHORITATIVE, 0 = otherwise)",
        registry=reg,
    )

    METRICS["operator_ledger_db_errors_total"] = Counter(
        "operator_ledger_db_errors_total",
        "Total operator ledger DB write errors",
        registry=reg,
    )

    # Operator action metrics (Phase 8: causality observability)
    METRICS["operator_action_active"] = Gauge(
        "operator_action_active",
        "Operator action active (1 = in-progress, 0 = idle)",
        ["action", "target", "policy"],
        registry=reg,
    )

    METRICS["operator_action_total"] = Counter(
        "operator_action_total",
        "Total operator actions observed",
        ["action", "target", "policy"],
        registry=reg,
    )

    METRICS["governance_enforcement_total"] = Counter(
        "governance_enforcement_total",
        "Governance enforcement outcomes",
        [
            "ccid",
            "scope_namespace",
            "scope_cluster",
            "scope_resource_type",
            "identity",
            "action",
            "result",
            "reason",
            "decision_hash",
            "aas_hash",
        ],
        registry=reg,
    )
    METRICS["governance_aas_issued_total"] = Counter(
        "governance_aas_issued_total",
        "Governance AAS issued events",
        [
            "ccid",
            "scope_namespace",
            "scope_cluster",
            "scope_resource_type",
            "identity",
            "action",
            "result",
            "reason",
            "decision_hash",
            "aas_hash",
        ],
        registry=reg,
    )
    METRICS["governance_decision_issued_total"] = Counter(
        "governance_decision_issued_total",
        "Governance decision issuance (CCID-bound)",
        [
            "ccid",
            "scope_namespace",
            "scope_cluster",
            "scope_resource_type",
            "identity",
            "action",
            "result",
            "reason",
            "decision_hash",
            "aas_hash",
        ],
        registry=reg,
    )
    METRICS["governance_active_aas"] = Gauge(
        "governance_active_aas",
        "Active AAS instances by scope",
        [
            "ccid",
            "scope_namespace",
            "scope_cluster",
            "scope_resource_type",
            "identity",
            "action",
            "result",
            "reason",
            "decision_hash",
            "aas_hash",
        ],
        registry=reg,
    )

    # Decision signature verification observability
    METRICS["decision_signature_verification_failures_total"] = Counter(
        "decision_signature_verification_failures_total",
        "DecisionRecord signature verification failures",
        ["reason"],
        registry=reg,
    )

    METRICS["decision_signature_verification_last_failure_ts"] = Gauge(
        "decision_signature_verification_last_failure_ts",
        "Unix timestamp of last DecisionRecord signature verification failure",
        registry=reg,
    )

    # Make audit / authority surface metrics
    METRICS["make_ungated_mutation_targets_total"] = Gauge(
        "make_ungated_mutation_targets_total",
        "Number of ungated mutation-capable Make targets (from MAKE_SYSTEM_STRUCTURAL_AUDIT.md)",
        registry=reg,
    )

    METRICS["make_authority_domain_count"] = Gauge(
        "make_authority_domain_count",
        "Count of Make targets by Authority Domain",
        ["domain"],
        registry=reg,
    )

    METRICS["doctor_authority_mode"] = Gauge(
        "doctor_authority_mode",
        "Doctor authority mode (1 = strict, 0 = advisory)",
        registry=reg,
    )

    # Trust continuity lifecycle metrics.
    METRICS["threadforge_trust_root_age_seconds"] = Gauge(
        "threadforge_trust_root_age_seconds",
        "Age of active trust root in seconds",
        registry=reg,
    )
    METRICS["threadforge_trust_publication_age_seconds"] = Gauge(
        "threadforge_trust_publication_age_seconds",
        "Seconds since trust publication alignment",
        registry=reg,
    )
    METRICS["threadforge_trust_publication_drift"] = Gauge(
        "threadforge_trust_publication_drift",
        "1 when distributed trust differs from active root",
        registry=reg,
    )
    METRICS["threadforge_trust_root_expiration_seconds"] = Gauge(
        "threadforge_trust_root_expiration_seconds",
        "Seconds until active trust root expiration",
        registry=reg,
    )
    METRICS["threadforge_trust_reconciliation_success_total"] = Counter(
        "threadforge_trust_reconciliation_success_total",
        "Total successful trust reconciliations",
        registry=reg,
    )
    METRICS["threadforge_trust_reconciliation_failure_total"] = Counter(
        "threadforge_trust_reconciliation_failure_total",
        "Total failed trust reconciliations",
        registry=reg,
    )
    METRICS["threadforge_trust_reconciliation_last_run_age_seconds"] = Gauge(
        "threadforge_trust_reconciliation_last_run_age_seconds",
        "Seconds since last reconciliation cycle completion",
        registry=reg,
    )
    METRICS["threadforge_trust_reconciliation_last_outcome_success"] = Gauge(
        "threadforge_trust_reconciliation_last_outcome_success",
        "1 when last reconciliation outcome was success/no_drift, else 0",
        registry=reg,
    )
    METRICS["threadforge_trust_source_mismatch_count"] = Gauge(
        "threadforge_trust_source_mismatch_count",
        "Number of trust sources that do not match active root",
        registry=reg,
    )
    METRICS["threadforge_trust_source_present"] = Gauge(
        "threadforge_trust_source_present",
        "1 when trust source payload is present",
        ["source"],
        registry=reg,
    )
    METRICS["threadforge_trust_source_match"] = Gauge(
        "threadforge_trust_source_match",
        "1 when trust source fingerprint matches active root",
        ["source"],
        registry=reg,
    )
    METRICS["threadforge_trust_publication_timestamp_set"] = Gauge(
        "threadforge_trust_publication_timestamp_set",
        "1 when publication timestamp is present",
        registry=reg,
    )
    METRICS["threadforge_trust_active_bundle_cert_count"] = Gauge(
        "threadforge_trust_active_bundle_cert_count",
        "Number of certificates in active SPIRE bundle",
        registry=reg,
    )
    METRICS["threadforge_trust_active_bundle_valid_cert_count"] = Gauge(
        "threadforge_trust_active_bundle_valid_cert_count",
        "Number of currently valid certificates in active SPIRE bundle",
        registry=reg,
    )
    METRICS["threadforge_trust_expiration_warning"] = Gauge(
        "threadforge_trust_expiration_warning",
        "1 when root expires in less than 24h",
        registry=reg,
    )
    METRICS["threadforge_trust_expiration_critical"] = Gauge(
        "threadforge_trust_expiration_critical",
        "1 when root expires in less than 12h",
        registry=reg,
    )
    METRICS["threadforge_trust_expiration_emergency"] = Gauge(
        "threadforge_trust_expiration_emergency",
        "1 when root expires in less than 1h",
        registry=reg,
    )

    # Demo invalid metrics removed after verification — exporter must not contain non-ASCII names.
    # See docs/observability/exporter-requirements.md for the canonical contract.


_TRUST_COUNTER_SNAPSHOT = {
    "threadforge_trust_reconciliation_success_total": 0.0,
    "threadforge_trust_reconciliation_failure_total": 0.0,
}


def _sync_trust_metrics_from_artifacts() -> None:
    """Best-effort sync from trust-authority artifacts produced by scripts/trust/."""
    state_path = Path("artifacts/trust/trust_authority_state.json")
    counters_path = Path("artifacts/trust/reconciler_counters.json")

    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
            METRICS["threadforge_trust_root_age_seconds"].set(float(state.get("root_age_seconds", 0.0) or 0.0))
            METRICS["threadforge_trust_publication_age_seconds"].set(
                float(state.get("publication_age_seconds", 0.0) or 0.0)
            )
            METRICS["threadforge_trust_publication_drift"].set(
                float(state.get("publication_drift", 0.0) or 0.0)
            )
            METRICS["threadforge_trust_root_expiration_seconds"].set(
                float(state.get("root_expiration_seconds", 0.0) or 0.0)
            )
            METRICS["threadforge_trust_source_mismatch_count"].set(
                float(state.get("source_mismatch_count", 0.0) or 0.0)
            )
            METRICS["threadforge_trust_publication_timestamp_set"].set(
                1.0 if str(state.get("publication_timestamp", "")).strip() else 0.0
            )
            METRICS["threadforge_trust_active_bundle_cert_count"].set(
                float(state.get("active_bundle_cert_count", 0.0) or 0.0)
            )
            METRICS["threadforge_trust_active_bundle_valid_cert_count"].set(
                float(state.get("active_bundle_valid_cert_count", 0.0) or 0.0)
            )

            for source in state.get("sources", []):
                source_name = str(source.get("name", "unknown"))
                METRICS["threadforge_trust_source_present"].labels(source=source_name).set(
                    1.0 if bool(source.get("present")) else 0.0
                )
                METRICS["threadforge_trust_source_match"].labels(source=source_name).set(
                    1.0 if bool(source.get("matches_active_root")) else 0.0
                )

            expiry = float(state.get("root_expiration_seconds", 0.0) or 0.0)
            METRICS["threadforge_trust_expiration_warning"].set(1.0 if expiry < 24 * 3600 else 0.0)
            METRICS["threadforge_trust_expiration_critical"].set(1.0 if expiry < 12 * 3600 else 0.0)
            METRICS["threadforge_trust_expiration_emergency"].set(1.0 if expiry < 3600 else 0.0)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional("sync trust state metrics", e)

    if counters_path.exists():
        try:
            counters = json.loads(counters_path.read_text(encoding="utf-8"))
            for key, metric_key in [
                ("success_total", "threadforge_trust_reconciliation_success_total"),
                ("failure_total", "threadforge_trust_reconciliation_failure_total"),
            ]:
                target_value = float(counters.get(key, 0.0) or 0.0)
                previous = float(_TRUST_COUNTER_SNAPSHOT.get(metric_key, 0.0))
                if target_value > previous:
                    METRICS[metric_key].inc(target_value - previous)
                _TRUST_COUNTER_SNAPSHOT[metric_key] = max(previous, target_value)

            now_epoch = time.time()
            last_run_epoch = float(counters.get("last_run_epoch", 0.0) or 0.0)
            METRICS["threadforge_trust_reconciliation_last_run_age_seconds"].set(
                max(0.0, now_epoch - last_run_epoch) if last_run_epoch > 0 else 0.0
            )
            METRICS["threadforge_trust_reconciliation_last_outcome_success"].set(
                1.0 if str(counters.get("last_result", "")).lower() in {"success", "no_drift"} else 0.0
            )
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional("sync trust counter metrics", e)


def prometheus_metrics() -> tuple[bytes, str]:
    reg = registry()
    _sync_trust_metrics_from_artifacts()
    return generate_latest(reg), CONTENT_TYPE_LATEST


# Backwards-compatible module-level alias expected by some tests
# Use registry() to ensure initialization; tolerates absent Prometheus client
REGISTRY = registry()


def _require_authoritative_telemetry() -> None:
    """Raise PermissionError if runtime is not authoritative.

    Use for telemetry surfaces that convey authority-sensitive information
    (governance/ledger/audit). This protects emission paths from being used
    when validated workload SVID is absent.
    """
    from runtime.authority.state import is_authoritative

    if not is_authoritative():
        raise PermissionError("Telemetry emission requires authoritative runtime / validated workload SVID")


def observe_decision_signature_failure(reason: str) -> None:
    """Increment failure counter and set last-failure timestamp.

    This emission is authority-sensitive and must not occur when the runtime
    is non-authoritative or lacks a validated workload SVID.
    """
    _require_authoritative_telemetry()
    registry()
    METRICS["decision_signature_verification_failures_total"].labels(reason=reason).inc(1)
    import time as _time

    METRICS["decision_signature_verification_last_failure_ts"].set(_time.time())


# -------------------------
# Make audit metrics helpers
# -------------------------
def update_make_audit_metrics(ungated_count: int, domain_counts: dict[str, int]) -> None:
    """Set Make-audit related metrics.

    - ungated_count: integer count of ungated mutation targets
    - domain_counts: mapping from Authority Domain name -> count

    This is purely observational telemetry derived from repository audit
    data; it does not affect runtime authority or enforcement.
    """
    registry()
    try:
        METRICS["make_ungated_mutation_targets_total"].set(int(ungated_count))
    except Exception:
        # best-effort: do not raise since metrics are advisory
        return

    # Known domains (keeps cardinality bounded); set 0 for missing domains
    known_domains = [
        "operator_infra",
        "control_wrapper",
        "confirm_gated",
        "generate_only",
        "read_only",
        "probe_ephemeral",
        "test_harness",
        "identity_gated",
    ]

    for d in known_domains:
        val = int(domain_counts.get(d, 0)) if domain_counts is not None else 0
        try:
            METRICS["make_authority_domain_count"].labels(domain=d).set(val)
        except Exception:
            # best-effort
            pass


def set_doctor_authority_mode(strict: bool) -> None:
    """Set current doctor authority mode gauge.

    - strict=True  => set gauge to 1
    - strict=False => set gauge to 0
    """
    registry()
    METRICS["doctor_authority_mode"].set(1 if strict else 0)


def get_decision_signature_failure_count(reason: str | None = None) -> float:
    """Return the current failure count for a reason or total (sum of all labels) for tests."""
    registry()
    try:
        if reason is not None:
            return float(METRICS["decision_signature_verification_failures_total"].labels(reason=reason)._value.get())
        # sum all label values
        # Note: This uses internal API of prometheus_client; acceptable for tests.
        total = 0.0
        metric = METRICS["decision_signature_verification_failures_total"]
        samples = metric._value.get()
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "get_decision_signature_failure_count", e
        )  # nosec B110: Metrics reading fallback should not raise
        return 0.0

    # For Counter with labels, metric._value is a dict-like. Sum its values.
    try:
        if isinstance(samples, dict):
            for v in samples.values():
                total += float(v)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "summing decision signature failure samples", e
        )  # nosec B110: Aggregation is best-effort; failure tolerated

    return total


def get_decision_signature_last_failure_ts() -> float:
    registry()
    try:
        return float(METRICS["decision_signature_verification_last_failure_ts"]._value.get())
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "read decision signature failure timestamp", e
        )  # nosec B110: Metrics are best-effort; reading fallback should not raise
        return 0.0


def update_ledger_lag(lag_seconds: float) -> None:
    """Update the ledger ingest lag metric.

    Only allowed when runtime is authoritative (ledger-derived metrics convey
    authoritative state). Fail-closed when identity/state is missing.
    """
    _require_authoritative_telemetry()
    METRICS["ledger_ingest_lag_seconds"].set(lag_seconds)


def observe_ledger_write(count: int = 1) -> None:
    """Increment ledger write operations counter."""
    _require_authoritative_telemetry()
    METRICS["ledger_write_operations_total"].inc(int(count))


def observe_operator_ledger_db_error(count: int = 1) -> None:
    """Increment ledger DB error counter (best-effort).

    Used by Level 7 chaos validation to prove DB failures are observable and alertable.
    """
    try:
        registry()
        METRICS["operator_ledger_db_errors_total"].inc(int(count))
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("observe_operator_ledger_db_error", e)  # nosec B110


def set_authority_authoritative(is_authoritative: bool) -> None:
    """Set authority gauge (best-effort)."""
    try:
        registry()
        METRICS["authority_authoritative"].set(1 if is_authoritative else 0)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("set_authority_authoritative", e)  # nosec B110


def update_identity_coverage(ratio: float) -> None:
    """Update the identity coverage ratio metric.

    Identity coverage is a health signal. It must remain observable even when
    the runtime is UNCLAIMED (no validated workload SVID), so it is intentionally
    NOT authority-gated.
    """
    try:
        registry()
        METRICS["identity_coverage_ratio"].set(float(ratio))
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("update_identity_coverage", e)  # nosec B110: metrics are best-effort


def observe_governance_metric(metric_name: str, metric_value: float, labels: dict[str, str]) -> None:
    """Update governance-related Prometheus metrics.

    This function is CCID-bound and authoritative only. It assumes all labels
    are already normalized and validated by the caller.
    """
    # Enforce authority for governance metrics (fail-closed)
    _require_authoritative_telemetry()
    registry()

    def _apply_labels(metric_obj: Any, labels_dict: dict[str, str]) -> dict[str, str]:
        # Filter incoming labels to the metric's declared label names to avoid
        # ValueError on unexpected keys (best-effort; caller must provide required keys).
        try:
            allowed = list(metric_obj._labelnames)
        except Exception:
            allowed = []
        filtered = {k: v for k, v in labels_dict.items() if k in allowed}
        return filtered

    if metric_name in {"governance.enforcement.allowed", "governance.enforcement.denied"}:
        metric = METRICS["governance_enforcement_total"]
        expected = getattr(metric, "_labelnames", [])
        filtered = {k: v for k, v in labels.items() if k in expected}
        metric.labels(**filtered).inc(metric_value)
        return

    if metric_name == "governance.aas.issued":
        metric = METRICS["governance_aas_issued_total"]
        expected = getattr(metric, "_labelnames", [])
        filtered = {k: v for k, v in labels.items() if k in expected}
        metric.labels(**filtered).inc(metric_value)
        return

    if metric_name == "governance.decision.issued":
        metric = METRICS["governance_decision_issued_total"]
        expected = getattr(metric, "_labelnames", [])
        filtered = {k: v for k, v in labels.items() if k in expected}
        metric.labels(**filtered).inc(metric_value)
        return

    if metric_name == "governance.aas.active":
        metric = METRICS["governance_active_aas"]
        expected = getattr(metric, "_labelnames", [])
        filtered = {k: v for k, v in labels.items() if k in expected}
        metric.labels(**filtered).set(metric_value)
        return
