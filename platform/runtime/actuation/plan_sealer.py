# ==============================================================================
# ThreadForge — Action Plan Sealer
# ------------------------------------------------------------------------------
# Produces a real cryptographic digest for an action plan.
#
# Guarantees:
#   - Deterministic hashing
#   - Tamper-evident plans
#   - Git-friendly diffs
#   - No execution
# ==============================================================================

from __future__ import annotations

import hashlib
import sys
from pathlib import Path
from typing import Any

import yaml

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext
from runtime.ledger.seal import AuthoritySeal


# ------------------------------------------------------------------------------
def canonical_bytes(data: dict[str, Any]) -> bytes:
    """Serialize deterministically so hashing is stable across machines."""
    return yaml.safe_dump(
        data,
        sort_keys=True,
        default_flow_style=False,
    ).encode("utf-8")


# ------------------------------------------------------------------------------
def compute_digest(plan: dict[str, Any]) -> str:
    """Hash ONLY the spec section.
    Metadata (timestamps, comments, etc.) are excluded.
    """
    spec = plan.get("spec")
    if not spec:
        raise ValueError("Plan has no spec section to seal")

    payload = canonical_bytes(spec)
    h = hashlib.sha256()
    h.update(payload)
    return f"sha256:{h.hexdigest()}"


# ------------------------------------------------------------------------------
def compute_policy_hash(policy_file: Path) -> str:
    """Compute hash of the governing policy file."""
    if not policy_file.exists():
        raise ValueError(f"Policy file not found: {policy_file}")

    with open(policy_file, "rb") as f:
        content = f.read()

    h = hashlib.sha3_512()
    h.update(content)
    return f"sha3-512:{h.hexdigest()}"


# ------------------------------------------------------------------------------
def seal_plan_with_authority(
    plan: dict[str, Any],
    identity: IdentityContext,
    effective_capabilities: CapabilitySet,
    decision_outcome: str,
    policy_file: Path | None = None,
) -> dict[str, Any]:
    """Seal a plan with cryptographic authority information.

    Phase 10: Authority sealing happens AFTER governance enforcement.
    """
    # First, compute the plan digest
    plan_digest = compute_digest(plan)

    # Compute policy hash (use default if not specified)
    if policy_file is None:
        policy_file = Path(__file__).parent.parent / "identity" / "policies.yaml"

    policy_hash = compute_policy_hash(policy_file)

    # Create authority seal
    authority_seal = AuthoritySeal.create(
        identity=identity,
        effective_capabilities=effective_capabilities,
        governing_policy_hash=policy_hash,
        decision_outcome=decision_outcome,
        plan_hash=plan_digest,
    )

    # Add seals to plan metadata
    metadata = plan.setdefault("metadata", {})
    metadata["digest"] = plan_digest
    metadata["authority_seal"] = {
        "seal_hash": authority_seal.compute_hash(),
        "seal_data": authority_seal.as_dict(),
    }
    metadata["sealed"] = True

    return plan


# ------------------------------------------------------------------------------
def seal_plan(plan: dict[str, Any]) -> dict[str, Any]:
    metadata = plan.setdefault("metadata", {})
    digest = compute_digest(plan)

    metadata["digest"] = digest
    metadata["sealed"] = True

    return plan


# ------------------------------------------------------------------------------
def load(path: Path) -> dict[str, Any]:
    with path.open("r") as f:
        return yaml.safe_load(f)


def save(path: Path, plan: dict[str, Any]) -> None:
    with path.open("w") as f:
        yaml.safe_dump(plan, f, sort_keys=False)


# ------------------------------------------------------------------------------
def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: plan_sealer.py <plan.yaml>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        sys.exit(2)

    plan = load(path)
    sealed = seal_plan(plan)
    save(path, sealed)

    print("Plan sealed")
    print(f"Digest: {sealed['metadata']['digest']}")
    print("NOTE: No execution has occurred.")


if __name__ == "__main__":
    main()
