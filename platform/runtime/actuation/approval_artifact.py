from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass
from typing import Any

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext
from runtime.ledger.seal import AuthoritySeal


def _sha3_512_hex(data: bytes) -> str:
    h = hashlib.sha3_512()
    h.update(data)
    return h.hexdigest()


def _stable_json(obj: Any) -> bytes:
    """Canonical JSON encoding for stable hashing.
    - sorted keys
    - no whitespace
    - UTF-8 bytes
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _compute_policy_hash() -> str:
    """Compute deterministic hash of the governing policy file.

    Returns the SHA3-512 hash of runtime/identity/policies.yaml.
    Used for metadata and audit trails only - never for enforcement.
    """
    policy_path = os.path.join(os.path.dirname(__file__), "..", "identity", "policies.yaml")

    try:
        with open(policy_path, "rb") as f:
            policy_content = f.read()
        return f"sha3-512:{_sha3_512_hex(policy_content)}"
    except (OSError, IOError):
        # If policy file cannot be read, return a deterministic placeholder
        # This ensures the system remains functional even if policy file is missing
        return "sha3-512:policy-file-unavailable"


def _yaml_quote(s: str) -> str:
    # Minimal safe quoting for YAML scalars (keeps monkey-proof output).
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _yaml_dump_minimal(d: dict[str, Any], indent: int = 0) -> str:
    """Minimal YAML serializer (no external dependency).
    Handles dict/list/scalar in a deterministic way.
    """
    pad = "  " * indent
    lines: list[str] = []

    def emit_kv(k: str, v: Any, level: int) -> None:
        p = "  " * level
        if isinstance(v, dict):
            lines.append(f"{p}{k}:")
            for kk in sorted(v.keys()):
                emit_kv(str(kk), v[kk], level + 1)
        elif isinstance(v, list):
            lines.append(f"{p}{k}:")
            for item in v:
                if isinstance(item, dict):
                    lines.append(f"{p}  -")
                    for kk in sorted(item.keys()):
                        emit_kv(str(kk), item[kk], level + 2)
                else:
                    lines.append(f"{p}  - { _yaml_scalar(item) }")
        else:
            lines.append(f"{p}{k}: { _yaml_scalar(v) }")

    def _yaml_scalar(x: Any) -> str:
        if x is None:
            return "null"
        if isinstance(x, bool):
            return "true" if x else "false"
        if isinstance(x, (int, float)):
            return str(x)
        return _yaml_quote(str(x))

    # expose scalar helper to closure
    globals()["_yaml_scalar"] = _yaml_scalar  # type: ignore[assignment]

    for key in sorted(d.keys()):
        emit_kv(str(key), d[key], indent)

    return "\n".join(lines) + "\n"


@dataclass(frozen=True)
class ApprovalArtifact:
    """Human approval record (file-friendly, git-friendly).

    This is NOT execution.
    This is the authorization primitive the Actuator Plane will later require.
    """

    artifact_version: str
    plan_id: str
    approved: bool
    reviewer: str
    rationale: str
    created_ts: float

    # Integrity anchors
    proposal_digest_sha3_512: str
    approval_digest_sha3_512: str

    # Phase 10: Authority sealing
    authority_seal_hash: str | None = None
    authority_seal_data: dict[str, Any] | None = None

    # Optional future expansion (not used yet)
    signature: str | None = None
    signature_alg: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "artifact_version": self.artifact_version,
            "plan_id": self.plan_id,
            "approved": self.approved,
            "reviewer": self.reviewer,
            "rationale": self.rationale,
            "created_ts": self.created_ts,
            "proposal_digest_sha3_512": self.proposal_digest_sha3_512,
            "approval_digest_sha3_512": self.approval_digest_sha3_512,
            "authority_seal_hash": self.authority_seal_hash,
            "authority_seal_data": self.authority_seal_data,
            "signature": self.signature,
            "signature_alg": self.signature_alg,
        }

    def to_yaml(self) -> str:
        return _yaml_dump_minimal(self.as_dict())


class ApprovalArtifactBuilder:
    """Builds approval YAML from a proposal dict.

    Inputs:
      - proposal_id: str (ActuationProposal.proposal_id)
      - proposal_payload: dict (the proposal you emitted / logged)
      - reviewer: human identity
      - approved: bool
      - rationale: short note
    """

    ARTIFACT_VERSION = "v1"

    @staticmethod
    def build(
        *,
        plan_id: str,
        proposal_payload: dict[str, Any],
        reviewer: str,
        approved: bool,
        rationale: str,
        created_ts: float | None = None,
    ) -> ApprovalArtifact:
        created_ts = created_ts or time.time()

        # Hash the proposal payload (tamper-evident input)
        proposal_digest = _sha3_512_hex(_stable_json(proposal_payload))

        # Hash the approval record itself (tamper-evident approval)
        approval_core = {
            "artifact_version": ApprovalArtifactBuilder.ARTIFACT_VERSION,
            "plan_id": plan_id,
            "approved": approved,
            "reviewer": reviewer,
            "rationale": rationale,
            "created_ts": created_ts,
            "proposal_digest_sha3_512": proposal_digest,
        }
        approval_digest = _sha3_512_hex(_stable_json(approval_core))

        return ApprovalArtifact(
            artifact_version=ApprovalArtifactBuilder.ARTIFACT_VERSION,
            plan_id=plan_id,
            approved=approved,
            reviewer=reviewer,
            rationale=rationale,
            created_ts=created_ts,
            proposal_digest_sha3_512=proposal_digest,
            approval_digest_sha3_512=approval_digest,
            authority_seal_hash=None,
            authority_seal_data=None,
            signature=None,
            signature_alg=None,
        )

    @staticmethod
    def build_with_authority_seal(
        *,
        plan_id: str,
        proposal_payload: dict[str, Any],
        reviewer: str,
        approved: bool,
        rationale: str,
        identity: IdentityContext,
        effective_capabilities: CapabilitySet,
        decision_outcome: str,
        plan_hash: str,
        created_ts: float | None = None,
    ) -> ApprovalArtifact:
        """Build approval artifact with cryptographic authority sealing.

        Phase 10: Authority sealing happens AFTER governance enforcement.
        """
        created_ts = created_ts or time.time()

        # Hash the proposal payload (tamper-evident input)
        proposal_digest = _sha3_512_hex(_stable_json(proposal_payload))

        # Hash the approval record itself (tamper-evident approval)
        approval_core = {
            "artifact_version": ApprovalArtifactBuilder.ARTIFACT_VERSION,
            "plan_id": plan_id,
            "approved": approved,
            "reviewer": reviewer,
            "rationale": rationale,
            "created_ts": created_ts,
            "proposal_digest_sha3_512": proposal_digest,
        }
        approval_digest = _sha3_512_hex(_stable_json(approval_core))

        # Create authority seal
        authority_seal = AuthoritySeal.create(
            identity=identity,
            effective_capabilities=effective_capabilities,
            governing_policy_hash=_compute_policy_hash(),
            decision_outcome=decision_outcome,
            plan_hash=plan_hash,
        )

        return ApprovalArtifact(
            artifact_version=ApprovalArtifactBuilder.ARTIFACT_VERSION,
            plan_id=plan_id,
            approved=approved,
            reviewer=reviewer,
            rationale=rationale,
            created_ts=created_ts,
            proposal_digest_sha3_512=proposal_digest,
            approval_digest_sha3_512=approval_digest,
            authority_seal_hash=authority_seal.compute_hash(),
            authority_seal_data=authority_seal.as_dict(),
            signature=None,
            signature_alg=None,
        )
