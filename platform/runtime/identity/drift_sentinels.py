# ThreadForge Tier 1.75 — Identity Drift Sentinels
#
# Alert-only sentinels for identity drift detection.
# No enforcement, pure observability.

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


@dataclass
class DriftAlert:
    """Identity drift alert for observability."""

    alert_id: str
    alert_type: str
    severity: str  # INFO, WARNING, CRITICAL
    identity_id: str
    description: str
    evidence: Dict[str, Any]
    timestamp: datetime


class IdentityDriftSentinels:
    """Tier 1.75: Identity drift detection sentinels.

    Monitors for impossible transitions and logical inconsistencies.
    Alert-only, no enforcement.
    """

    def __init__(self) -> None:
        self._alerts: List[DriftAlert] = []
        self._execution_history: Dict[str, List[Dict[str, Any]]] = {}

    def check_execution_event(
        self, identity_id: str, operation: str, authority_seal: Optional[Dict[str, Any]] = None
    ) -> List[DriftAlert]:
        """Check for impossible transitions: execution without prior authority seal."""
        alerts = []

        # Sentinel A: Impossible Transitions
        if not authority_seal:
            alert = DriftAlert(
                alert_id=f"drift-{len(self._alerts) + 1}",
                alert_type="IMPOSSIBLE_TRANSITION",
                severity="CRITICAL",
                identity_id=identity_id,
                description="Execution event occurred without prior AuthoritySeal",
                evidence={
                    "operation": operation,
                    "authority_seal_present": False,
                    "violation": "execution_without_seal",
                },
                timestamp=datetime.now(timezone.utc),
            )
            alerts.append(alert)
            logger.warning(f"Identity drift detected: {alert.description}")

        # Track execution history for other sentinels
        if identity_id not in self._execution_history:
            self._execution_history[identity_id] = []

        self._execution_history[identity_id].append(
            {"operation": operation, "timestamp": datetime.now(timezone.utc), "authority_seal": authority_seal}
        )

        # Keep only recent history (last 100 events per identity)
        if len(self._execution_history[identity_id]) > 100:
            self._execution_history[identity_id] = self._execution_history[identity_id][-100:]

        return alerts

    def check_delegation_timing(
        self, identity_id: str, delegation_window: tuple[datetime, datetime], current_time: datetime
    ) -> List[DriftAlert]:
        """Check for delegation time violations."""
        alerts = []

        # Sentinel B: Delegation Time Violations
        valid_from, valid_until = delegation_window
        if not (valid_from <= current_time <= valid_until):
            alert = DriftAlert(
                alert_id=f"drift-{len(self._alerts) + 1}",
                alert_type="DELEGATION_TIME_VIOLATION",
                severity="CRITICAL",
                identity_id=identity_id,
                description="Delegation used outside valid time window",
                evidence={
                    "current_time": current_time.isoformat(),
                    "valid_from": valid_from.isoformat(),
                    "valid_until": valid_until.isoformat(),
                    "violation": "time_window_violation",
                },
                timestamp=datetime.now(timezone.utc),
            )
            alerts.append(alert)
            logger.warning(f"Identity drift detected: {alert.description}")

        return alerts

    def check_capability_entropy(
        self, identity_id: str, previous_capabilities: set[str], current_capabilities: set[str]
    ) -> List[DriftAlert]:
        """Check for capability entropy drift without policy updates."""
        alerts = []

        # Sentinel C: Capability Entropy Drift
        if len(previous_capabilities) != len(current_capabilities):
            alert = DriftAlert(
                alert_id=f"drift-{len(self._alerts) + 1}",
                alert_type="CAPABILITY_ENTROPY_DRIFT",
                severity="WARNING",
                identity_id=identity_id,
                description="Capability set cardinality changed without policy update",
                evidence={
                    "previous_count": len(previous_capabilities),
                    "current_count": len(current_capabilities),
                    "previous_capabilities": sorted(previous_capabilities),
                    "current_capabilities": sorted(current_capabilities),
                    "violation": "entropy_drift",
                },
                timestamp=datetime.now(timezone.utc),
            )
            alerts.append(alert)
            logger.info(f"Identity drift detected: {alert.description}")

        return alerts

    def check_identity_lineage(self, identity_id: str, authority_paths: List[str]) -> List[DriftAlert]:
        """Check for identity lineage forks (same identity, divergent authority paths)."""
        alerts = []

        # Sentinel D: Identity Lineage Forks
        if len(set(authority_paths)) > 1:  # Multiple different paths
            alert = DriftAlert(
                alert_id=f"drift-{len(self._alerts) + 1}",
                alert_type="IDENTITY_LINEAGE_FORK",
                severity="WARNING",
                identity_id=identity_id,
                description="Identity exhibits divergent authority paths",
                evidence={
                    "authority_paths": authority_paths,
                    "unique_paths": len(set(authority_paths)),
                    "violation": "lineage_fork",
                },
                timestamp=datetime.now(timezone.utc),
            )
            alerts.append(alert)
            logger.info(f"Identity drift detected: {alert.description}")

        return alerts

    def get_recent_alerts(self, limit: int = 50) -> List[DriftAlert]:
        """Get recent drift alerts for observability."""
        return self._alerts[-limit:] if self._alerts else []

    def emit_metrics(self) -> Dict[str, Any]:
        """Emit sentinel metrics for observability."""
        total_alerts = len(self._alerts)
        alerts_by_type: dict[str, int] = {}
        alerts_by_severity: dict[str, int] = {}

        for alert in self._alerts[-1000:]:  # Last 1000 alerts
            alerts_by_type[alert.alert_type] = alerts_by_type.get(alert.alert_type, 0) + 1
            alerts_by_severity[alert.severity] = alerts_by_severity.get(alert.severity, 0) + 1

        return {
            "identity_drift_sentinels": {
                "total_alerts": total_alerts,
                "alerts_by_type": alerts_by_type,
                "alerts_by_severity": alerts_by_severity,
                "active_identities": len(self._execution_history),
            }
        }


# Global sentinel instance
_drift_sentinels = IdentityDriftSentinels()


def get_drift_sentinels() -> IdentityDriftSentinels:
    """Get global identity drift sentinels instance."""
    return _drift_sentinels
