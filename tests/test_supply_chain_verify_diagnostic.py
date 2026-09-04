from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_supply_chain_endpoint_scan_reports_advisory_state_truthfully() -> None:
    text = (ROOT / "scripts/make/supplychain.mk").read_text(encoding="utf-8")
    target = text.split("supply-chain-verify:", 1)[1].split("supply-chain-verify-runtime:", 1)[0]
    assert "[ADVISORY] external tooling endpoint(s) remain outside CI authority" in target
    assert "[ADVISORY-FAIL]" not in target
    assert "ERROR: forbidden external tooling endpoint" not in target
