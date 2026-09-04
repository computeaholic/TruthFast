import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "docs/architecture/system-model/project_obligations.json"
REQUIRED_FIELDS = {
    "OBLIGATION_ID",
    "SOURCE",
    "SOURCE_ID",
    "TITLE",
    "OWNER",
    "CLASS",
    "STATUS",
    "CURRENT_AUTHORITY",
    "CURRENT_IMPLEMENTATION",
    "EVIDENCE",
    "V1_RELEVANCE",
    "POST_V1_RELEVANCE",
    "BLOCKER",
    "NEXT_ACTION",
    "DISPOSITION",
}


def _ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def test_project_obligation_ledger_is_complete_and_resolved() -> None:
    ledger = _ledger()
    obligations = ledger["OBLIGATIONS"]
    assert obligations
    for obligation in obligations:
        assert REQUIRED_FIELDS <= set(obligation), obligation["OBLIGATION_ID"]
        assert obligation["STATUS"] != "UNKNOWN_REQUIRES_INVESTIGATION"
        assert obligation["EVIDENCE"]
    assert ledger["PROJECT_STATE"]["OPEN_REAL_V1_OBLIGATIONS"] == 0
    assert ledger["PROJECT_STATE"]["UNKNOWN_OBLIGATIONS"] == 0


def test_all_ten_starting_github_issues_are_individually_adjudicated() -> None:
    issues = {
        int(item["SOURCE_ID"])
        for item in _ledger()["OBLIGATIONS"]
        if item["SOURCE"] == "GitHub issue"
    }
    assert issues == set(range(545, 555))


def test_adr_authority_and_runtime_qualification_are_explicit() -> None:
    ledger = _ledger()
    adrs = [item for item in ledger["OBLIGATIONS"] if item["SOURCE"] == "ADR"]
    assert {item["SOURCE_ID"] for item in adrs} == {"0001", "0002", "0003", "0004", "0005"}
    assert [item["SOURCE_ID"] for item in adrs if item["CLASS"] == "ACTIVE_ADR"] == ["0001"]
    assert ledger["RUNTIME_QUALIFIED_SHA"] == "0ddae102badf2a93fe4fdb3934ad9a36db4c8c84"


def test_current_qualification_projection_is_source_consistent() -> None:
    ledger = _ledger()
    source_sha = ledger["RUNTIME_QUALIFIED_SHA"]
    model = json.loads(
        (ROOT / "docs/architecture/system-model/system_model.json").read_text(encoding="utf-8")
    )
    provenance = (ROOT / "docs/releases/PUBLIC_RELEASE_PROVENANCE.md").read_text(encoding="utf-8")
    baseline = (ROOT / "docs/releases/CERTIFICATION_BASELINE.md").read_text(encoding="utf-8")

    assert ledger["QUALIFICATION_EVIDENCE"]["SOURCE_SHA"] == source_sha
    assert model["final_runtime_qualified_sha"] == source_sha
    assert f"`{source_sha}`" in provenance
    assert ledger["HISTORICAL_QUALIFICATION_EVIDENCE"]["SOURCE_SHA"] == "b7e8612b94089dd574d7064d709427add22dbd51"
    assert "Runtime-qualified SHA: `b7e8612b94089dd574d7064d709427add22dbd51`" in baseline
    assert "Previous runtime-qualified SHA: `34082cfb4e3b0173f09dc7aeabfa7abb5ad201aa`" in baseline
