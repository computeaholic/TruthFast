from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_observability_verifier_hardens_tempo_stabilization() -> None:
    text = _read("scripts/verify/verify_observability_stack.sh")

    assert 'STACK_TIMEOUT_SECONDS="${OBSERVABILITY_STACK_TIMEOUT_SECONDS:-120}"' in text
    assert 'TEMPO_ROLLOUT_TIMEOUT_SECONDS="${OBSERVABILITY_STACK_TEMPO_ROLLOUT_TIMEOUT_SECONDS:-180}"' in text
    assert 'TEMPO_RETRY_ATTEMPTS="${OBSERVABILITY_STACK_TEMPO_RETRY_ATTEMPTS:-5}"' in text
    assert (
        'run_kubectl rollout status statefulset/tempo -n observability --timeout="${TEMPO_ROLLOUT_TIMEOUT_SECONDS}s"'
        in text
    )
    assert "run_kubectl -n observability get endpoints tempo -o json" in text
    assert "jq -e '(.subsets // []) | length > 0'" in text
    assert "run_kubectl -n observability get pvc -o json" in text
    assert 'record_contract_fail "Tempo failed to stabilize within the proof window"' in text


def test_prove_system_allows_extended_observability_window() -> None:
    text = _read("scripts/prove_system.sh")

    assert 'local observability_timeout="${OBSERVABILITY_STEP_TIMEOUT_SECONDS:-360}"' in text


def test_tempo_values_raise_resource_floor() -> None:
    text = _read("platform/deploy/infra/tempo/values.yaml")

    assert "cpu: 250m" in text
    assert "memory: 1Gi" in text
    assert "cpu: 1000m" in text
    assert "memory: 2Gi" in text
