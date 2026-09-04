"""Intent Registry — Externalized Intent Classification

Phase P1.6: Externalize Intent Registry

This module loads the intent registry from the ConfigMap and provides
classification of intents as internal (control-plane only) or user-facing.

File: runtime/ai/intent_registry.py
"""

from __future__ import annotations

import fnmatch
import json
import logging
import time
from typing import List, Set

import yaml

log = logging.getLogger(__name__)
INTENT_REGISTRY_FILE = "/etc/threadforge/intents.yaml"


class IntentRegistry:
    """Externalized intent registry loaded from ConfigMap."""

    def __init__(self, config_file: str = INTENT_REGISTRY_FILE):
        """Load intent registry from YAML ConfigMap.

        Args:
            config_file: Path to intents.yaml (from ConfigMap mount)

        Raises:
            FileNotFoundError: If config file not found
            ValueError: If config is malformed
        """
        try:
            with open(config_file) as f:
                self.config = yaml.safe_load(f)

            # Validate structure
            if not isinstance(self.config, dict) or "registry" not in self.config:
                raise ValueError("Invalid intent registry format: missing 'registry' key")

            # Extract internal and user-facing intents
            registry = self.config["registry"]

            # Internal intents (literal + patterns)
            internal_config = registry.get("internal", {})
            self.internal_literals: Set[str] = set(internal_config.get("literal", []))
            self.internal_patterns: List[str] = internal_config.get("patterns", [])

            # User-facing intents
            self.user_facing: Set[str] = set(registry.get("user_facing", []))

            # Log registry loaded
            self._log_structured(
                {
                    "event": "intent_registry_loaded",
                    "file": config_file,
                    "internal_literals": len(self.internal_literals),
                    "internal_patterns": len(self.internal_patterns),
                    "user_facing": len(self.user_facing),
                }
            )

            log.info(
                f"Intent registry loaded: {len(self.internal_literals)} internal literals, "
                f"{len(self.internal_patterns)} patterns, {len(self.user_facing)} user-facing"
            )
        except FileNotFoundError:
            log.error(f"Intent registry file not found: {config_file}")
            raise
        except (yaml.YAMLError, ValueError) as e:
            log.error(f"Failed to parse intent registry: {e}")
            raise

    def is_internal(self, intent: str) -> bool:
        """Check if intent is internal (control-plane only).

        Returns True if the intent:
        - Matches a literal internal intent (exact match)
        - Matches an internal pattern (glob pattern)

        Args:
            intent: Intent name to check

        Returns:
            True if intent is internal, False otherwise
        """
        # Check literal matches
        if intent in self.internal_literals:
            return True

        # Check pattern matches
        for pattern in self.internal_patterns:
            if fnmatch.fnmatch(intent, pattern):
                return True

        return False

    def is_user_facing(self, intent: str) -> bool:
        """Check if intent is user-facing (external API).

        Args:
            intent: Intent name to check

        Returns:
            True if intent is user-facing, False otherwise
        """
        return intent in self.user_facing

    def validate_intent(self, intent: str) -> None:
        """Validate that intent is either internal or user-facing.

        Raises:
            ValueError: If intent is not in registry
        """
        if not (self.is_internal(intent) or self.is_user_facing(intent)):
            raise ValueError(f"Unknown intent: {intent}")

    def _log_structured(self, event: dict) -> None:
        """Log structured event to logs/operator_api.jsonl."""
        try:
            with open("artifacts/logs/operator_api.jsonl", "a") as f:
                f.write(json.dumps({**event, "ts": time.time()}) + "\n")
        except IOError as e:
            log.error(f"Failed to write structured log: {e}")


# Global registry instance (loaded at bootstrap)
_INTENT_REGISTRY: IntentRegistry | None = None


def get_registry() -> IntentRegistry:
    """Get global intent registry instance.

    Returns:
        IntentRegistry: Global registry loaded at bootstrap

    Raises:
        RuntimeError: If registry not yet initialized
    """
    if _INTENT_REGISTRY is None:
        raise RuntimeError("Intent registry not initialized; call init_registry() at startup")
    return _INTENT_REGISTRY


def init_registry(config_file: str = INTENT_REGISTRY_FILE) -> IntentRegistry:
    """Initialize global intent registry at bootstrap.

    Args:
        config_file: Path to intents.yaml ConfigMap

    Returns:
        IntentRegistry: Loaded registry
    """
    global _INTENT_REGISTRY
    _INTENT_REGISTRY = IntentRegistry(config_file)
    return _INTENT_REGISTRY


def is_internal_intent(intent: str) -> bool:
    """Check if intent is internal (control-plane only).

    This is the main API used by operator_core.py.

    Args:
        intent: Intent name

    Returns:
        True if internal, False otherwise
    """
    return get_registry().is_internal(intent)


def is_user_facing_intent(intent: str) -> bool:
    """Check if intent is user-facing (external API).

    Args:
        intent: Intent name

    Returns:
        True if user-facing, False otherwise
    """
    return get_registry().is_user_facing(intent)
