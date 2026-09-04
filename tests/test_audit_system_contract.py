from __future__ import annotations

from pathlib import Path


def _read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def test_supported_audit_surface_excludes_legacy_k3s_dispatchers() -> None:
    makefile = _read("Makefile")
    pre_push = _read(".githooks/pre-push")
    assert "audit-k3s-" not in makefile
    assert "audit-experimental-" not in makefile
    assert "make audit, audit-check" in makefile
    assert "make audit-check" in pre_push
    assert "audit-authority" not in pre_push


def test_canonical_audit_propagates_required_failures() -> None:
    runner = _read("scripts/audit/run_full_audit.sh")
    utils = _read("scripts/audit/lib/utils.sh")
    assert "AUDIT_STATUS=FAIL" in runner
    assert "grep -q $'\\tFAIL\\t'" in runner
    assert "return 2" in runner
    assert '"status": overall_status' in runner
    assert '"source_sha"' not in runner  # report names the field git_sha
    assert '"git_sha": git_sha' in runner
    assert 'AUDIT_PHASE_STATUS=""' in utils
    assert 'if [[ -z "$AUDIT_PHASE_STATUS" ]]' in utils


def test_dynamic_demo_registry_authority_is_source_and_signature_bound() -> None:
    manifest = _read("platform/labs/agent-containment/k8s/deployments.yaml")
    producer = _read("scripts/install/prepare_agents_lab_images.sh")
    audit = _read("scripts/verify/registry_audit.sh")

    assert manifest.count("threadforge.io/source-sha: THREADFORGE_SOURCE_SHA") == 4
    assert 'SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"' in producer
    assert 'sed -i "s/THREADFORGE_SOURCE_SHA/${SOURCE_SHA}/g"' in producer
    assert 'bound_sha != source_sha' in audit
    assert 'not verify_signature(ref)' in audit
    assert '"source_bound_dynamic_demo_images"' in audit


def test_value_plane_audit_has_explicit_fail_closed_predicates() -> None:
    audit = _read("scripts/audit/value_plane_audit.sh")
    assert 'required_tables" != "4"' in audit
    assert 'duplicate_rows" != "0"' in audit
    assert 'null_identity_rows" != "0"' in audit
    assert 'missing_lineage_rows" != "0"' in audit
    assert 'exit 2' in audit
