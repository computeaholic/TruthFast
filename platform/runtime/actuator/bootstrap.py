# ==============================================================================
# ThreadForge — Actuator Plane Bootstrap
# ------------------------------------------------------------------------------
# Responsibility:
#   - Register passive actuator-plane observers
#   - NEVER enable execution
#   - NEVER mutate governance
#
# This file is safe to import unconditionally.
# ==============================================================================

from __future__ import annotations


def bootstrap_actuator_plane() -> None:
    """Initialize actuator-plane observers and exporters.

    This function is intentionally idempotent and side-effect minimal.
    """
    # Register plan state registry (authoritative lifecycle tracker)
    from runtime.actuator.plan_state_registry import PlanStateRegistry

    PlanStateRegistry.get_instance()

    # Register Grafana exporter (observability only)
    from runtime.actuator.plan_grafana_exporter import PlanGrafanaExporter

    PlanGrafanaExporter()

    # Register governance Grafana exporter (observability only)
    from runtime.actuator.governance_grafana_exporter import GovernanceGrafanaExporter

    GovernanceGrafanaExporter()

    # Emit initial governance state for observability
    GovernanceGrafanaExporter.emit_snapshot()
