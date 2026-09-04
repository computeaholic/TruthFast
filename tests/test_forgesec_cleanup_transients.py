from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_forgesec_transient_cleanup_is_shared_and_authoritative() -> None:
    cleanup = (REPO_ROOT / "scripts" / "forgesec" / "cleanup_transients.sh").read_text(encoding="utf-8")
    verify = (REPO_ROOT / "scripts" / "verify" / "verify_forgesec_enforcement.sh").read_text(encoding="utf-8")
    settle = (REPO_ROOT / "scripts" / "verify" / "wait_for_determinism_settle.sh").read_text(encoding="utf-8")
    makefile = (REPO_ROOT / "scripts" / "make" / "forgesec.mk").read_text(encoding="utf-8")

    assert "kubectl delete jobs -n \"$namespace\" -l app=forgesec --ignore-not-found" in cleanup
    assert "kubectl delete pods -n \"$namespace\" -l app=forgesec --ignore-not-found" in cleanup
    assert "cleanup_transients.sh" in verify
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in verify
    assert "cleanup_transients.sh" not in settle
    assert "wait_for_system_ready.sh" in settle
    assert "kyverno_has_no_active_transients" in settle
    assert "kyverno-cleanup-" in settle
    assert 'select(any((.metadata.ownerReferences // [])[]?; .kind == "Job"))' in settle
    assert "cleanup_transients.sh" in makefile
    assert 'bash scripts/verify/verify_forgesec_enforcement.sh' in makefile
    forgesec_target = makefile[makefile.index("\nforgesec:\n"):makefile.index("\n# ----------------------------------------------------------------------------\n# Cleanup Old Jobs")]
    assert "forgesec-identity-k8s" not in forgesec_target
    assert '"http.unauth.grafana"' in verify
    assert '"http.unauth.tempo"' in verify
    assert '"tempo.write.unauth"' in verify
