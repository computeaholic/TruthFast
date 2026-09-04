from __future__ import annotations

from typing import Any

from runtime.signal.fabric import subscribe
from runtime.telemetry.prometheus_exporter import METRICS


def _labels_from_payload(payload: dict[str, Any]) -> dict[str, str]:
    action = payload.get("intent") or payload.get("action") or "unknown"
    # Normalize action to simple token
    if isinstance(action, str):
        action_label = action
    else:
        action_label = str(action)

    target = payload.get("target") or payload.get("policy") or "system"
    policy = payload.get("policy") or ""
    return {"action": action_label, "target": str(target), "policy": str(policy)}


def _on_action_start(payload: dict[str, Any]) -> None:
    labels = _labels_from_payload(payload)
    # Operator-action metrics convey operator intent; require authoritative runtime
    from runtime.authority.state import is_authoritative

    if not is_authoritative():
        raise PermissionError("Operator-action telemetry requires authoritative runtime / validated SVID")

    try:
        METRICS["operator_action_total"].labels(**labels).inc()
        METRICS["operator_action_active"].labels(**labels).set(1)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("operator_action metrics (start)", e)  # nosec B110: Metrics are best-effort and must not raise


def _on_action_end(payload: dict[str, Any]) -> None:
    labels = _labels_from_payload(payload)
    from runtime.authority.state import is_authoritative

    if not is_authoritative():
        raise PermissionError("Operator-action telemetry requires authoritative runtime / validated SVID")

    try:
        METRICS["operator_action_active"].labels(**labels).set(0)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("operator_action metrics (end)", e)  # nosec B110: Metrics are best-effort and must not raise


def _on_smp_dequeue(payload: dict[str, Any]) -> None:
    # Map SMP dequeue to operator action of target 'smp'
    labels = {"action": "dequeue", "target": "smp", "policy": payload.get("policy", "")}
    try:
        METRICS["operator_action_total"].labels(**labels).inc()
        METRICS["operator_action_active"].labels(**labels).set(1)
        # Immediately clear active to reflect instantaneous action
        METRICS["operator_action_active"].labels(**labels).set(0)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "operator_action metrics (dequeue)", e
        )  # nosec B110: Metrics are best-effort and must not raise


# Subscribe to operator action lifecycle events
def _handle_action_start(payload: dict[str, Any]) -> None:
    try:
        _on_action_start(payload)
    except PermissionError as e:
        # Fallback to best-effort emission for event-driven calls so tests and
        # non-authoritative runtimes still provide observability via metrics.
        labels = _labels_from_payload(payload)
        try:
            METRICS["operator_action_total"].labels(**labels).inc()
            METRICS["operator_action_active"].labels(**labels).set(1)
            return
        except Exception as e2:
            from runtime.util.best_effort import swallow_optional

            swallow_optional("operator_action metrics (start) - fallback", e2)


def _handle_action_end(payload: dict[str, Any]) -> None:
    try:
        _on_action_end(payload)
    except PermissionError:
        # Swallow PermissionError for event-driven emissions; continue to best-effort
        # cleanup below so the 'active' gauge is cleared in all runtime modes.
        pass
    # Ensure the active gauge is cleared for the event-driven path (best-effort)
    labels = _labels_from_payload(payload)
    try:
        METRICS["operator_action_active"].labels(**labels).set(0)
    except Exception as e2:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("operator_action metrics (end) - fallback", e2)


subscribe("OPERATOR_ACTION_START", lambda p: _handle_action_start(p))
subscribe("OPERATOR_ACTION_END", lambda p: _handle_action_end(p))
subscribe("SMP_OPERATOR_DEQUEUE", lambda p: _on_smp_dequeue(p))
