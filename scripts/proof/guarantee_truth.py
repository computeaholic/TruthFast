#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = REPO_ROOT / "scripts" / "contracts" / "proof_guarantee_classes.json"


def load_contract() -> dict[str, Any]:
    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    if contract.get("proof_heals_canonical_state") is not False:
        raise ValueError("proof guarantee contract must prohibit healing canonical state")
    return contract


def derive_truth_model(doc: dict[str, Any], execution_mode: str, include_active: bool) -> dict[str, Any]:
    guarantees = doc.get("guarantees")
    if not isinstance(guarantees, dict):
        raise ValueError("missing guarantees block in status.json")
    malformed = sorted(name for name, entry in guarantees.items() if not isinstance(entry, dict))
    if malformed:
        raise ValueError(f"malformed guarantee entries: {malformed}")

    contract = load_contract()
    active_names = set(contract["active_guarantees"])
    missing_active = sorted(active_names - set(guarantees))
    if missing_active:
        raise ValueError(f"active guarantee classification references missing guarantees: {missing_active}")

    passive_status = "PASS" if all(
        entry.get("status") == "PASS"
        for name, entry in guarantees.items()
        if name not in active_names
    ) else "FAIL"
    active_status = "PASS" if all(
        guarantees[name].get("status") == "PASS" for name in active_names
    ) and all(doc.get(field) == "PASS" for field in contract["active_top_level_fields"]) else "FAIL"

    if execution_mode != "proof":
        mutation_mode = "active_assurance"
    elif include_active:
        mutation_mode = contract["canonical_proof_mutation_mode"]
    else:
        mutation_mode = "passive_only"

    blocked = sorted(
        [name for name, entry in guarantees.items() if isinstance(entry, dict) and entry.get("status") == "BLOCKED"]
        + [field for field in contract["active_top_level_fields"] if doc.get(field) == "BLOCKED"]
    )
    not_evaluated = sorted(
        name
        for name, entry in guarantees.items()
        if isinstance(entry, dict) and entry.get("status") == "NOT_EVALUATED"
    )
    return {
        "active_guarantees": active_status,
        "blocked_guarantees": blocked,
        "not_evaluated_guarantees": not_evaluated,
        "passive_guarantees": passive_status,
        "proof_heals_canonical_state": False,
        "proof_mutation_mode": mutation_mode,
        "read_only_guarantees": passive_status,
    }


def augment(path: Path, execution_mode: str, include_active: bool) -> None:
    doc = json.loads(path.read_text(encoding="utf-8"))
    doc.update(derive_truth_model(doc, execution_mode, include_active))
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Derive canonical proof guarantee truth fields")
    parser.add_argument("command", choices=("augment",))
    parser.add_argument("status", type=Path)
    parser.add_argument("--execution-mode", required=True)
    parser.add_argument("--include-active", choices=("true", "false"), required=True)
    args = parser.parse_args()

    augment(args.status, args.execution_mode, args.include_active == "true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
