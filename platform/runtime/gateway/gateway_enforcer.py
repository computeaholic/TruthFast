# ThreadForge PPIT Gateway - Capability Enforcer
#
# Reference Architecture Only
#
# Enforces CapabilitySet using existing require() primitives.

import json
import logging
import os
import time
from enum import Enum
from typing import Any, Dict, List

import yaml

from .gateway_context import IdentityContext

log = logging.getLogger(__name__)
CAPABILITY_MATRIX_FILE = "/etc/threadforge/capability-matrix.yaml"


class Capability(Enum):
    """ThreadForge capability types."""

    READ = "read"
    WRITE = "write"
    EXECUTE = "execute"
    ADMIN = "admin"


class EnforcementResult:
    """Result of capability enforcement."""

    def __init__(self, allowed: bool, reason: str, required_caps: List[str]) -> None:
        self.allowed = allowed
        self.reason = reason
        self.required_caps = required_caps


class GatewayEnforcer:
    """PPIT Gateway capability enforcer using existing require() primitives."""

    def __init__(self) -> None:
        # Load capability matrix from ConfigMap (Finding #11)
        try:
            with open(CAPABILITY_MATRIX_FILE) as f:
                config = yaml.safe_load(f)

            # Validate file structure
            if not isinstance(config, dict) or "capabilities" not in config:
                raise ValueError("Invalid capability matrix format: missing 'capabilities' key")

            self._capability_matrix: Dict[str, List[str]] = config["capabilities"]

            # Log matrix loaded
            log_structured(
                {
                    "event": "capability_matrix_loaded",
                    "file": CAPABILITY_MATRIX_FILE,
                    "entries": len(self._capability_matrix),
                    "timestamp": time.time(),
                }
            )

            log.info(f"Capability matrix loaded with {len(self._capability_matrix)} entries")
        except FileNotFoundError:
            log.error(f"Capability matrix file not found: {CAPABILITY_MATRIX_FILE}")
            raise
        except (yaml.YAMLError, ValueError) as e:
            log.error(f"Failed to parse capability matrix: {e}")
            raise

    def require(self, context: IdentityContext, operation: str) -> EnforcementResult:
        """
        Enforce capability requirements using existing require() pattern.

        Args:
            context: Validated identity context
            operation: Operation being requested

        Returns:
            EnforcementResult indicating allow/deny with reason
        """
        # Check if operation is defined in capability matrix
        if operation not in self._capability_matrix:
            return EnforcementResult(allowed=False, reason=f"Unknown operation: {operation}", required_caps=[])

        required_caps = self._capability_matrix[operation]
        granted_caps = [Capability(cap) for cap in context.capabilities.keys() if cap in required_caps]

        # Check if all required capabilities are granted
        missing_caps = [cap for cap in required_caps if Capability(cap) not in granted_caps]

        if missing_caps:
            return EnforcementResult(
                allowed=False,
                reason=f"Missing capabilities: {', '.join(missing_caps)}",
                required_caps=list(required_caps),
            )

        return EnforcementResult(
            allowed=True, reason="All required capabilities present", required_caps=list(required_caps)
        )

    def check_delegation_depth(self, context: IdentityContext, max_depth: int = 3) -> bool:
        """
        Check delegation chain depth limit.

        Args:
            context: Identity context to check
            max_depth: Maximum allowed delegation depth

        Returns:
            True if delegation depth is acceptable
        """
        return len(context.delegation_chain) <= max_depth

    def validate_operation_scope(self, context: IdentityContext, operation: str, resource: str) -> bool:
        """
        Validate that operation is allowed on specific resource.

        Args:
            context: Identity context
            operation: Operation type
            resource: Target resource

        Returns:
            True if operation is allowed on resource
        """
        # Extract namespace from resource
        if "/" in resource:
            resource_ns = resource.split("/")[0]
            return context.namespace == resource_ns

        return True  # Allow if no namespace specified


def log_structured(event: dict[str, Any]) -> None:
    """Log structured event to artifacts/logs/operator_api.jsonl."""
    os.makedirs("artifacts/logs", exist_ok=True)
    with open("artifacts/logs/operator_api.jsonl", "a") as f:
        f.write(json.dumps(event) + "\n")
