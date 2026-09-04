from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]

OUTPUT_AUTHORITY_MATRIX = [
    {
        "target": "make audit",
        "script": "scripts/audit/run_full_audit.sh",
        "output_path": "artifacts/audit/<run>",
        "consumer": "artifacts/audit/LATEST and make mermaids",
    },
    {
        "target": "make mermaids",
        "script": "scripts/generate_mermaids.py",
        "output_path": "artifacts/mermaid/<run>",
        "consumer": "scripts/debug/view_diagrams.sh",
    },
    {
        "target": "make forgesec",
        "script": "scripts/make/forgesec.mk",
        "output_path": "artifacts/forgesec/<run>",
        "consumer": "make security-gate",
    },
    {
        "target": "dump runtime images",
        "script": "scripts/debug/dump_runtime_images.sh",
        "output_path": "artifacts/runtime/runtime_images.txt",
        "consumer": "scripts/debug/classify_drift.sh and scripts/debug/diff_cluster_images.sh",
    },
]


def test_output_authority_matrix_is_canonical() -> None:
    for entry in OUTPUT_AUTHORITY_MATRIX:
        assert entry["output_path"].startswith("artifacts/")
        assert entry["script"].startswith("scripts/") or entry["script"].startswith("tools/")


def test_audit_paths_are_canonical() -> None:
    run_full_audit = (REPO_ROOT / "scripts" / "audit" / "run_full_audit.sh").read_text()
    assert "audit_output" not in run_full_audit
    assert "artifacts/audit" in run_full_audit
    assert "artifacts/mermaid" in run_full_audit


def test_mermaid_sources_have_no_ppit_content() -> None:
    for relative_path in (
        Path("scripts/generate_mermaids.py"),
        Path("scripts/audit/generate_mermaids.py"),
        Path("scripts/debug/view_diagrams.sh"),
    ):
        content = (REPO_ROOT / relative_path).read_text().lower()
        assert "ppit" not in content


def test_forgesec_no_longer_uses_advisory_success_paths() -> None:
    for relative_path in (
        Path("scripts/make/forgesec.mk"),
        Path("platform/images/forgesec/forgesec.sh"),
    ):
        assert "[ADVISORY-FAIL]" not in (REPO_ROOT / relative_path).read_text()


def test_forgesec_entrypoint_terminates_proxy_on_exit() -> None:
    text = (REPO_ROOT / "platform" / "images" / "forgesec" / "forgesec.sh").read_text()
    assert "quitquitquit" in text
    assert "trap shutdown_proxy EXIT" in text


def test_runtime_inventory_paths_are_canonical() -> None:
    for relative_path in (
        Path("scripts/debug/dump_runtime_images.sh"),
        Path("scripts/debug/diff_cluster_images.sh"),
        Path("scripts/debug/classify_drift.sh"),
        Path("scripts/debug/debug_cluster_integrity.sh"),
    ):
        content = (REPO_ROOT / relative_path).read_text()
        assert "artifacts/runtime" in content


def test_root_leaks_absent() -> None:
    for relative_path in (
        Path("audit_output"),
        Path("cosign.key"),
        Path("proof.log"),
        Path("proof-https.log"),
        Path("proof-https-2.log"),
        Path("proof-https-final.log"),
        Path("runtime_images.txt"),
        Path("sds_trace.log"),
    ):
        assert not (REPO_ROOT / relative_path).exists(), f"unexpected root leak: {relative_path}"
