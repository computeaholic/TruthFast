from __future__ import annotations

import copy

import pytest

from scripts.proof.guarantee_truth import derive_truth_model, load_contract


def _all_pass_document() -> dict:
    contract = load_contract()
    active = set(contract["active_guarantees"])
    passive = {"identity_spiffe", "registry_completeness", "deterministic_output"}
    return {
        "admission_rejection": "PASS",
        "ephemeral_containers_blocked": "PASS",
        "guarantees": {name: {"status": "PASS"} for name in sorted(active | passive)},
    }


def test_canonical_proof_distinguishes_passive_and_bounded_active_assurance() -> None:
    truth = derive_truth_model(_all_pass_document(), execution_mode="proof", include_active=True)

    assert truth["passive_guarantees"] == "PASS"
    assert truth["active_guarantees"] == "PASS"
    assert truth["read_only_guarantees"] == truth["passive_guarantees"]
    assert truth["proof_mutation_mode"] == "bounded_active_assurance"
    assert truth["proof_heals_canonical_state"] is False


def test_passive_and_active_failures_remain_independently_fail_closed() -> None:
    passive_failure = copy.deepcopy(_all_pass_document())
    passive_failure["guarantees"]["registry_completeness"]["status"] = "FAIL"
    passive_truth = derive_truth_model(passive_failure, execution_mode="proof", include_active=True)
    assert passive_truth["passive_guarantees"] == "FAIL"
    assert passive_truth["active_guarantees"] == "PASS"

    active_failure = copy.deepcopy(_all_pass_document())
    active_failure["guarantees"]["admission_enforced"]["status"] = "FAIL"
    active_truth = derive_truth_model(active_failure, execution_mode="proof", include_active=True)
    assert active_truth["passive_guarantees"] == "PASS"
    assert active_truth["active_guarantees"] == "FAIL"


def test_classification_cannot_silently_reference_missing_active_guarantee() -> None:
    document = _all_pass_document()
    del document["guarantees"]["admission_enforced"]

    with pytest.raises(ValueError, match="missing guarantees"):
        derive_truth_model(document, execution_mode="proof", include_active=True)
