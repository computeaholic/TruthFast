from __future__ import annotations

import json
import pathlib
import re
import subprocess
import importlib.util
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "trust" / "trust_authority.py"


def _read(rel: str) -> str:
    return (REPO_ROOT / rel).read_text(encoding="utf-8")


def _load_trust_authority_module():
    spec = importlib.util.spec_from_file_location("trust_authority_test_module", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _fingerprint_from_pem(pem: str) -> str:
    proc = subprocess.run(
        ["openssl", "x509", "-noout", "-fingerprint", "-sha256"],
        input=pem,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return proc.stdout.strip().split("=", 1)[-1].strip()


def test_update_trust_authority_state_writes_validate_freshness_fields() -> None:
    text = _read("scripts/trust/update_trust_authority_state.sh")
    assert "trust_authority.py" in text
    assert "export-state" in text
    assert "active_root_pem does not match active_root_serial" in text
    assert "active_root_pem must contain exactly one certificate" in text
    assert "source_observed_at" in text


def test_trust_authority_exported_state_includes_freshness_metadata() -> None:
    text = _read("scripts/trust/trust_authority.py")
    assert '"source_observed_at": now_iso' in text
    assert '"source_observed_at_epoch": now_epoch' in text
    assert '"spire_bundle_sha256": bundle_sha256' in text
    assert "write_text(json.dumps(state" in text
    assert "replace(state_path)" in text


def test_bundle_sources_select_the_active_certificate_from_multi_cert_pems() -> None:
    module = _load_trust_authority_module()
    state = json.loads((REPO_ROOT / "artifacts" / "trust" / "trust_authority_state.json").read_text(encoding="utf-8"))
    active_pem = str(state.get("active_root_pem") or "").strip()
    stale_pem = (REPO_ROOT / "artifacts" / "trust" / "root.pem").read_text(encoding="utf-8").strip()
    assert active_pem
    assert stale_pem
    bundle = f"{stale_pem}\n{active_pem}\n"
    active_fp = _fingerprint_from_pem(active_pem).replace(":", "").lower()
    selected = module._select_pem_from_bundle(bundle, active_fingerprint_sha256=active_fp)
    assert _fingerprint_from_pem(selected).replace(":", "").lower() == active_fp


def test_freshness_sensitive_callers_refresh_unconditionally_before_state_use() -> None:
    callers = (
        "scripts/verify/refresh_spire_istio_ca_path.sh",
        "scripts/verify/converge_spire_root.sh",
        "scripts/verify/verify_trust_root_immutability.sh",
        "scripts/verify/verify_spire_root_consistency.sh",
        "scripts/verify/verify_root_lifecycle_continuity.sh",
        "scripts/verify/verify_runtime_identity_truth.sh",
        "scripts/verify/verify_no_istio_ca_fallback.sh",
        "scripts/verify/verify_workload_spire_issuers.sh",
        "scripts/verify/verify_gateway_ca_source.sh",
        "scripts/verify/verify_identity_chain.sh",
        "scripts/prove_system.sh",
        "scripts/infra/bootstrap.sh",
    )
    for rel in callers:
        text = _read(rel)
        assert "update_trust_authority_state.sh" in text, rel
        assert "|| true" not in text.split("update_trust_authority_state.sh", 1)[1].splitlines()[0], rel


def test_identity_chain_selects_active_root_from_bundle_snapshot() -> None:
    text = _read("scripts/verify/verify_identity_chain.sh")
    inspect_fn = text.split("def inspect_cert(pem: str) -> dict[str, Any]:", 1)[1].split(
        "def inspect_cert_validity", 1
    )[0]
    admin_fn = text.split("def parse_admin_identity(admin_doc: dict[str, Any], expected_spiffe: str) -> dict[str, Any]:", 1)[1].split(
        "def recursive_find_paths", 1
    )[0]
    select_fn = text.split("def select_current_spire_root(spire_roots: list[str]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:", 1)[1].split(
        "def normalize_serial", 1
    )[0]
    assert "normalize_serial(line.split(\"=\", 1)[1].strip().lower())" in inspect_fn
    assert "normalize_serial(str(leaf.get(\"serial_number\", \"\")).strip().lower())" in admin_fn
    assert "normalize_serial(str(ca.get(\"serial_number\", \"\")).strip().lower())" in admin_fn
    assert "sorted(" in select_fn
    assert "normalize_serial(item[2].get(\"serial\", \"\"))" in select_fn
    assert "SPIRE ACTIVE authority was not found uniquely in the bundle" not in select_fn


def test_trust_state_artifact_is_single_cert_and_self_consistent() -> None:
    subprocess.run(
        [str(REPO_ROOT / "scripts" / "trust" / "update_trust_authority_state.sh")],
        check=True,
        cwd=REPO_ROOT,
    )
    state_path = REPO_ROOT / "artifacts" / "trust" / "trust_authority_state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    pem = str(state.get("active_root_pem") or "")
    assert pem.count("BEGIN CERTIFICATE") == 1
    assert pem.count("END CERTIFICATE") == 1
    assert state.get("source_observed_at")
    assert state.get("source_observed_at_epoch") is not None
    assert state.get("spire_bundle_sha256")
    assert re.search(r"^20\d\d-", str(state.get("generated_at") or "")) or state.get("generated_at")
