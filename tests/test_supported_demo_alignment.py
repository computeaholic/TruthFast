from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_containment_demo_fails_closed_on_assertion_mismatch() -> None:
    text = (REPO_ROOT / "Makefile").read_text()

    assert "failures=$$((failures + 1))" in text
    assert 'exit 1' in text


def test_security_demo_delegates_to_canonical_forgesec_target() -> None:
    text = (REPO_ROOT / "scripts" / "make" / "civ.mk").read_text()

    assert "@$(MAKE) forgesec" in text
    assert "tools/dev/security/demo_security_boundary.sh" not in text


def test_authority_contrast_does_not_swallow_fixture_failures() -> None:
    makefile = (REPO_ROOT / "scripts" / "make" / "civ.mk").read_text()
    loader = (REPO_ROOT / "tools" / "dev" / "demo" / "demo_load_identity_authority_full.sh").read_text()

    assert "demo_load_identity_authority_full.sh || true" not in makefile
    assert "clickhouse-client --multiquery < \"$SQL_FILE\" || true" not in loader


def test_authority_enrichment_uses_ephemeral_outputs() -> None:
    runner = (REPO_ROOT / "tools" / "verify" / "civ" / "civ_identity_enrichment_test_runner.sh").read_text()
    generator = (REPO_ROOT / "tools" / "dev" / "demo" / "generate_full_demo_sql.sh").read_text()

    assert 'WORK_DIR="$(mktemp -d' in runner
    assert 'DEMO_FULL_SQL_OUTPUT:-tools/dev/demo/demo_identity_authority_full.sql' in generator


def test_containment_setup_uses_canonical_runtime_and_fails_closed() -> None:
    deploy = (REPO_ROOT / "scripts" / "install" / "deploy_lab.sh").read_text()
    validator = (REPO_ROOT / "scripts" / "advisory" / "validate_spire.sh").read_text()

    assert "run_required_validation" in deploy
    assert "install_spire.sh" not in deploy
    assert "install_istio.sh" not in deploy
    assert 'echo "[ADVISORY-FAIL] non-authoritative path"' not in deploy
    assert 'source "${REPO_ROOT}/scripts/lib/spire_server_socket.sh"' in validator
    assert '"${SPIRE_SERVER_SOCKET_PATH}"' in validator
    assert "/opt/spire/bin/spire-agent healthcheck" in validator
    assert '"${SPIRE_AGENT_SOCKET_PATH}"' in validator
    assert "logs do not show successful registration/identity activity" not in validator
    assert "/run/spire/data/server.sock" not in validator
    assert 'LAB_RESOLVED="${RESOLVED_DEPLOYMENTS}"' in deploy
    runtime_model = (REPO_ROOT / "scripts" / "advisory" / "verify_runtime_image_model.sh").read_text()
    assert 'RUNTIME_NAMESPACE="${RUNTIME_NAMESPACE:-agents-lab}"' in runtime_model
    assert "verify_runtime_images.sh" in runtime_model
    assert "deletionTimestamp" in runtime_model
    assert 'echo "[ADVISORY-FAIL] non-authoritative path"' not in runtime_model


def test_demo_all_owns_exact_supported_inventory_and_mutation_gate() -> None:
    runner = (REPO_ROOT / "scripts" / "demo" / "run_supported_demos.sh").read_text()
    makefile = (REPO_ROOT / "Makefile").read_text()

    assert "demo-all:" in makefile
    for target in ("demo", "demo-civ", "demo-authority-contrast", "demo-security-boundary"):
        assert f"run_demo" in runner
        assert f" {target}" in runner
    assert "status --porcelain --untracked-files=no" in runner
    assert "SOURCE_MUTATION: ${source_mutation}" in runner
    assert "SUPPORTED_DEMO_SOURCE_MUTATION: ${source_mutation}" in runner
    assert "[[ \"${final}\" == \"PASS\" ]]" in runner


def test_authority_artifact_move_ignores_existing_destination_directories(tmp_path: Path) -> None:
    artifact_root = tmp_path / "artifacts" / "civ" / "identity-enrichment-test"
    older = artifact_root / "20260823T234700Z"
    newer = artifact_root / "20260823T234806Z"
    baseline = artifact_root / "baseline"
    older.mkdir(parents=True)
    newer.mkdir(parents=True)
    baseline.mkdir(parents=True)

    mover = REPO_ROOT / "tools" / "dev" / "demo" / "move_last_identity_artifact.sh"
    result = subprocess.run(
        ["bash", str(mover), "artifacts/civ/identity-enrichment-test/baseline"],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert (baseline / newer.name).is_dir()
    assert not (baseline / baseline.name).exists()
    assert older.is_dir()
