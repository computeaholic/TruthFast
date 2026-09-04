import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = REPO_ROOT / "docs" / "architecture" / "system-model"
FORENSIC_DIR = REPO_ROOT / "reports" / "forensics" / "threadforge-system-atlas-20260827T040440Z"


def _json(name: str):
    return json.loads((MODEL_DIR / name).read_text(encoding="utf-8"))


def test_system_inventory_resolves_support_and_qualification_for_every_system() -> None:
    inventory = _json("system_inventory.json")

    assert len(inventory) == 54
    assert len({row["SYSTEM_ID"] for row in inventory}) == 54
    assert all(row["SUPPORT_TIER"] for row in inventory)
    assert all(row["QUALIFICATION_SCOPE"] for row in inventory)
    assert all("SUPPORTED_ENTRYPOINT" not in row for row in inventory)
    assert sum(row["QUALIFICATION_SCOPE"] == "NATIVE_V1_QUALIFIED" for row in inventory) == 31
    assert sum(row["SUPPORT_TIER"] == "SECONDARY" for row in inventory) == 4
    assert sum(row["SUPPORT_TIER"] == "HISTORICAL" for row in inventory) == 3

    api = next(row for row in inventory if row["SYSTEM_ID"] == "SYS-018")
    assert api["REACHED_BY_SUPPORTED_V1_PATH"] is False
    assert api["SUPPORT_TIER"] == "SECONDARY"
    assert api["QUALIFICATION_SCOPE"] == "SECONDARY_UNQUALIFIED"


def test_claim_evidence_model_has_future_graph_boundary_without_new_authority() -> None:
    model = _json("claim_evidence.json")
    required = {
        "CLAIM_ID",
        "SYSTEM_ID",
        "GUARANTEE_ID",
        "PRODUCER",
        "VERIFIER",
        "EVIDENCE",
        "RUN_ID",
        "SOURCE_SHA",
        "IDENTITY",
        "AUTHORITY",
        "OBSERVATION_TYPE",
        "RESULT",
        "CONFIDENCE",
    }

    assert model["authority"] == "DESCRIPTIVE_REFERENCE_METADATA_ONLY"
    assert model["qualification_authority"] is False
    assert required == set(model["fields"])
    assert all(required.issubset(claim) for claim in model["claims"])


def test_forensic_snapshot_is_complete_and_render_validation_is_terminal() -> None:
    files = [path for path in FORENSIC_DIR.rglob("*") if path.is_file()]
    validation = _json("mermaid_render_validation.json")

    assert len(files) == 80
    assert len(list((FORENSIC_DIR / "diagrams").glob("*.mmd"))) == 20
    assert validation["total"] == 20
    assert validation["rendered"] == 20
    assert validation["render_failures"] == 0
    assert len(validation["results"]) == 20


def test_canonical_atlas_routes_to_single_support_contract() -> None:
    atlas = (REPO_ROOT / "docs" / "architecture" / "SYSTEM_ATLAS.md").read_text(encoding="utf-8")
    normalized = " ".join(atlas.split())

    assert "platform/config/support_contract.json" in atlas
    assert "secondary application mediation kernel" in atlas
    assert "not native V1 qualified, and not cold-start supported" in normalized
    assert "descriptive/reference metadata in V1" in atlas
