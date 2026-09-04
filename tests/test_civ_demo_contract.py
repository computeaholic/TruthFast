from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_demo_civ_declares_value_plane_prerequisites() -> None:
    text = (REPO_ROOT / "scripts" / "make" / "civ.mk").read_text()

    expected = (
        "demo-civ: value-plane-schema-apply value-plane-semantics "
        "value-plane-policy-economics value-plane-budgets value-plane-counterfactual"
    )
    assert expected in text
