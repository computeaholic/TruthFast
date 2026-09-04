# ======================================================================
# ThreadForge — ObservationPlane API (READ-ONLY)
# Path: runtime/api/observability_api.py
# ======================================================================
"""READ-ONLY observability surface for CCID-scoped link-outs.

Grafana is a view-layer pointer only. All correlation occurs here.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException

from runtime.api.operator_introspection import require_observability_identity
from runtime.civ.provenance.decision_record import DecisionRecord
from runtime.governance.allowed_action_set import AllowedActionSet
from runtime.governance.crypto_integrity import get_signer
from internal.observability.causal_correlation import is_signal_authoritative
from internal.observability.observation_plane import ObservationPlane

router = APIRouter(prefix="/observe", tags=["observability"])


def _load_decision_by_hash(decision_hash: str, artifact_dir: str = "artifacts/civ/decisions") -> Dict[str, Any] | None:
    path = Path(artifact_dir)
    if not path.exists():
        return None

    signer = get_signer()

    for candidate in path.glob("*.json"):
        data = json.loads(candidate.read_text(encoding="utf-8"))
        if data.get("provenance_hash") != decision_hash:
            continue
        signature = data.get("signature", "")
        if not signature:
            raise ValueError("DecisionRecord missing signature")
        record = DecisionRecord.from_dict(data)
        if not signer.verify(record.to_dict(), signature):
            raise ValueError("DecisionRecord signature verification failed")
        return data

    return None


def _load_aas_by_hash(aas_hash: str, artifact_dir: str = "artifacts/aas") -> Dict[str, Any] | None:
    path = Path(artifact_dir)
    if not path.exists():
        return None

    signer = get_signer()

    for candidate in path.glob("*.json"):
        data = json.loads(candidate.read_text(encoding="utf-8"))
        if data.get("provenance_hash") != aas_hash:
            continue
        signature = data.get("signature", "")
        if not signature:
            raise ValueError("AllowedActionSet missing signature")
        aas = AllowedActionSet.from_dict(data)
        if not signer.verify(aas.canonical_form(), signature):
            raise ValueError("AllowedActionSet signature verification failed")
        return data

    return None


@router.get("")
def observe_ccid(ccid: str, identity=Depends(require_observability_identity)) -> Dict[str, Any]:
    """Return authoritative causal chain for a CCID.

    Grafana must only link to this endpoint; it must not infer causality.
    """
    if not ccid:
        raise HTTPException(status_code=400, detail="ccid is required")

    plane = ObservationPlane()
    plane.load()
    chain = plane.get_chain_by_ccid(ccid)

    if chain is None:
        raise HTTPException(status_code=404, detail="ccid not found")

    return chain.to_dict()


@router.get("/logs")
def observe_logs(ccid: str, identity=Depends(require_observability_identity)) -> Dict[str, Any]:
    """Return CCID-scoped authoritative log entries."""
    if not ccid:
        raise HTTPException(status_code=400, detail="ccid is required")

    log_path = Path("artifacts/logs/observability_causal.jsonl")
    if not log_path.exists():
        raise HTTPException(status_code=404, detail="causal log not found")

    entries = []
    for line in log_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("ccid") != ccid:
            continue
        if not is_signal_authoritative(record):
            continue
        entries.append(record)

    return {"ccid": ccid, "entries": entries}


@router.get("/artifacts")
def observe_artifacts(ccid: str, identity=Depends(require_observability_identity)) -> Dict[str, Any]:
    """Return sealed DecisionRecord + AAS artifacts for a CCID."""
    if not ccid:
        raise HTTPException(status_code=400, detail="ccid is required")

    plane = ObservationPlane()
    plane.load()
    chain = plane.get_chain_by_ccid(ccid)

    if chain is None:
        raise HTTPException(status_code=404, detail="ccid not found")

    decision = _load_decision_by_hash(chain.decision_hash)
    aas = _load_aas_by_hash(chain.aas_hash) if chain.aas_hash else None

    if decision is None:
        raise HTTPException(status_code=404, detail="DecisionRecord artifact not found")

    if chain.aas_hash and aas is None:
        raise HTTPException(status_code=404, detail="AllowedActionSet artifact not found")

    return {
        "ccid": ccid,
        "decision": decision,
        "aas": aas,
    }
