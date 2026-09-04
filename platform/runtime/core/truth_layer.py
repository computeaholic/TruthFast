# ==============================================================================
# File: operator/core/truth_layer.py
# ThreadForge — Truth Layer
# Authoritative validation + reflex gateway for Operator-AI
# ==============================================================================
from __future__ import annotations

import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from threading import Lock
from typing import Any

from runtime.ai.kernel.reflex_hooks import ReflexHooks
from runtime.ai.kernel.threshold_engine import ReflexVerdict, ThresholdEngine, ThresholdRequest
from runtime.contracts.forgesec_contract import compute_forgesec_payload_hash
from runtime.core.identity_policy import enforce_identity_policy
from runtime.core.intent_registry import KernelIntent


@dataclass(frozen=True)
class ForgeSecObservation:
    identity_pass: bool
    surface_pass: bool
    violation_count: int
    timestamp: datetime

    def as_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["timestamp"] = self.timestamp.isoformat()
        return data


class TruthLayer:
    """Authoritative SMPEnvelope safety layer.
    Applies:
        - envelope validation
        - namespace correctness
        - threshold scoring
        - reflex safety veto
        - lineage-aware priority
    """

    VALID_NAMESPACES = {
        "vector",
        "api",
        "civsim",
        "weave",
        "mesh",
        "pki",
    }

    _forgesec_lock = Lock()
    _forgesec_observation: ForgeSecObservation | None = None
    _forgesec_observation_hash: str | None = None
    FORGESEC_MAX_AGE_SECONDS = 900

    def __init__(self):
        self.thresholds = ThresholdEngine()
        self.reflex = ReflexHooks()

    @staticmethod
    def _parse_timestamp(value: Any) -> datetime:
        if isinstance(value, datetime):
            dt = value
        elif isinstance(value, str) and value:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        else:
            dt = datetime.now(timezone.utc)

        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)

    @staticmethod
    def _to_bool(value: Any, default: bool = False) -> bool:
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in {"1", "true", "yes", "pass", "passed", "ok"}
        if isinstance(value, (int, float)):
            return bool(value)
        return default

    @classmethod
    def ingest_forgesec_observation(cls, observation: ForgeSecObservation | dict[str, Any]) -> ForgeSecObservation:
        if isinstance(observation, ForgeSecObservation):
            normalized = observation
        else:
            current = cls.get_forgesec_observation()
            observations = observation.get("observations") or {}
            mode = str(observation.get("mode") or observation.get("suite") or "").strip().lower()
            result = str(observation.get("result") or observation.get("status") or "").strip().lower()

            identity_pass = current.identity_pass if current else False
            surface_pass = current.surface_pass if current else False

            if "identity_pass" in observation:
                identity_pass = cls._to_bool(observation.get("identity_pass"))
            elif "identity_pass" in observations:
                identity_pass = cls._to_bool(observations.get("identity_pass"))
            elif mode == "identity":
                identity_pass = result == "pass"

            if "surface_pass" in observation:
                surface_pass = cls._to_bool(observation.get("surface_pass"))
            elif "surface_pass" in observations:
                surface_pass = cls._to_bool(observations.get("surface_pass"))
            elif mode == "surface":
                surface_pass = result == "pass"

            violation_value = observation.get("violation_count")
            if violation_value is None:
                violation_value = observations.get("violation_count", observations.get("violations"))
            if violation_value is None and result == "fail":
                violation_value = 1
            try:
                violation_count = int(violation_value or 0)
            except (TypeError, ValueError):
                violation_count = 0

            normalized = ForgeSecObservation(
                identity_pass=identity_pass,
                surface_pass=surface_pass,
                violation_count=max(0, violation_count),
                timestamp=cls._parse_timestamp(observation.get("timestamp")),
            )

        # Hash only canonical normalized payload so recomputation is deterministic
        # and independent of caller-provided extra fields.
        observation_hash = compute_forgesec_payload_hash(normalized.as_dict())

        with cls._forgesec_lock:
            cls._forgesec_observation = normalized
            cls._forgesec_observation_hash = observation_hash
        return normalized

    @classmethod
    def get_forgesec_observation(cls) -> ForgeSecObservation | None:
        with cls._forgesec_lock:
            return cls._forgesec_observation

    @classmethod
    def get_forgesec_observation_hash(cls) -> str | None:
        with cls._forgesec_lock:
            return cls._forgesec_observation_hash

    @classmethod
    def get_forgesec_state(cls) -> ForgeSecObservation:
        observation = cls.get_forgesec_observation()
        if observation is not None:
            return observation
        return ForgeSecObservation(
            identity_pass=False,
            surface_pass=False,
            violation_count=1,
            timestamp=datetime.now(timezone.utc),
        )

    @classmethod
    def evaluate_forgesec_authority(cls) -> tuple[bool, str | None]:
        observation = cls.get_forgesec_observation()
        if observation is None:
            return False, "FORGESEC_STATE_MISSING"

        now = datetime.now(timezone.utc)
        age_seconds = (now - observation.timestamp).total_seconds()
        if age_seconds > cls.FORGESEC_MAX_AGE_SECONDS:
            from runtime.governance.enforcement import GovernanceViolation

            raise GovernanceViolation("FORGESEC_STALE")

        if observation.violation_count > 0:
            return False, "SECURITY_VIOLATION"
        if not observation.identity_pass:
            return False, "IDENTITY_BROKEN"
        if not observation.surface_pass:
            return False, "SURFACE_BROKEN"
        return True, None

    # -----------------------------------------------------------------
    # MAIN VERIFICATION
    # -----------------------------------------------------------------
    def verify(self, envelope):
        """Required envelope fields:
        - signed
        - src
        - dst
        - op
        - payload
        - priority (0–10)
        """
        now = time.time()

        expires = getattr(envelope, "expires_ts", None)
        if expires is not None and now > expires:
            raise RuntimeError("TruthLayer: expired SMPEnvelope rejected")

        intent = getattr(envelope, "intent", None)
        try:
            KernelIntent(intent)
        except Exception as err:
            raise RuntimeError(f"TruthLayer: unknown or unauthorized intent '{intent}'") from err

        # ------------------------------------------------------------
        # Phase 6B — Identity-Class Enforcement (PPIT)
        # ------------------------------------------------------------
        identity_context = getattr(envelope, "identity_context", {})
        decision = enforce_identity_policy(identity_context, intent)

        if decision == "deny":
            raise RuntimeError(
                f"PPIT enforcement deny: identity_class={identity_context.get('identity_class')} intent={intent}",
            )

        # ------------------------------------------------------
        # Signed (fail-closed default)
        # ------------------------------------------------------
        # Envelopes MUST be explicitly marked as signed to be trusted.
        if not getattr(envelope, "signed", False):
            raise RuntimeError("TruthLayer: unsigned SMPEnvelope rejected")

        # ------------------------------------------------------
        # Destination
        # ------------------------------------------------------
        dst = getattr(envelope, "dst", None)
        if dst not in self.VALID_NAMESPACES:
            raise RuntimeError(f"TruthLayer: invalid dst '{dst}'")

        # ------------------------------------------------------
        # Priority sanity
        # ------------------------------------------------------
        pr = getattr(envelope, "priority", None)
        if pr is None or not isinstance(pr, int) or not (0 <= pr <= 10):
            raise RuntimeError("TruthLayer: priority must be 0–10 integer")

        # ------------------------------------------------------
        # Normalize payload
        # ------------------------------------------------------
        raw = envelope.payload
        if hasattr(raw, "__dict__"):
            p = raw.__dict__
        elif isinstance(raw, dict):
            p = raw
        else:
            p = {"value": raw}

        # ------------------------------------------------------
        # Score request
        # ------------------------------------------------------
        score_req = ThresholdRequest(
            module=dst,
            action=getattr(envelope, "op", "unknown"),
            payload=p,
            priority=pr,
            model=p.get("model", ""),
            vector_dim=p.get("dimension", 0),
            load=p.get("load", 0.0),
            namespace=getattr(envelope, "dst", ""),
            identity_context=getattr(envelope, "identity_context", {}),
        )

        verdict = self.thresholds.evaluate(score_req)

        if verdict == ReflexVerdict.BLOCK:
            raise RuntimeError("TruthLayer: BLOCK verdict — unsafe request")

        return verdict

    # -----------------------------------------------------------------
    # Reflex veto
    # -----------------------------------------------------------------
    def reflex_veto(self, envelope):
        verdict = self.verify(envelope)

        # Reflex veto kicks in ONLY at block-level danger
        if verdict == ReflexVerdict.BLOCK:
            return "block"

        return "allow"
