from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
CLUSTER_IMAGE_MAP = REPO_ROOT / "platform" / "config" / "cluster_image_map.json"


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _state_fingerprint(path: Path) -> str:
    raw = path.read_bytes()
    normalized = json.dumps(json.loads(raw.decode("utf-8")), sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(normalized).hexdigest()


def _make_harness(tmp_path: Path) -> tuple[dict[str, str], Path, Path, Path]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    call_log = tmp_path / "calls.log"
    ca_cert = tmp_path / "ca.crt"
    cache_file = tmp_path / "runtime-image-convergence.json"
    cluster_map_path = tmp_path / "cluster_image_map.json"

    ca_cert.write_text("dummy-ca", encoding="utf-8")
    cluster_map_path.write_text(CLUSTER_IMAGE_MAP.read_text(encoding="utf-8"), encoding="utf-8")

    _write_executable(
        fake_bin / "kubectl",
        f"""#!/usr/bin/env bash
set -euo pipefail
log() {{ printf '%s\\n' "kubectl $*" >> "{call_log}"; }}
log "$@"
case "$*" in
  *"config current-context"*) printf 'kind-threadforge\\n'; exit 0 ;;
  *"get pod -n threadforge-system"*) exit 0 ;;
  *"get namespace "*|*" get ns "*) exit 0 ;;
  *"get secret registry-credentials"*) exit 0 ;;
  *"get deploy/"*|*"get daemonset/"*|*"get deployment/"*) exit 0 ;;
  *"create secret docker-registry"*) exit 0 ;;
  *"create namespace"*) exit 0 ;;
  *"patch "*|*"apply "*|*"rollout restart "*|*"rollout status "*|*"delete "*|*"set env "*) exit 0 ;;
  *) exit 0 ;;
esac
""",
    )

    _write_executable(
        fake_bin / "skopeo",
        f"""#!/usr/bin/env bash
set -euo pipefail
log() {{ printf '%s\\n' "skopeo $*" >> "{call_log}"; }}
log "$@"
case "$1" in
  inspect)
    ref="${{@: -1}}"
    digest="${{ref##*@}}"
    printf '%s\\n' "$digest"
    ;;
  copy)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
""",
    )

    _write_executable(
        fake_bin / "cosign",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "cosign $*" >> "{call_log}"
exit 0
""",
    )

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin}:{env['PATH']}",
            "REGISTRY_CA_CERT_PATH": str(ca_cert),
            "RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE": str(cache_file),
            "RUNTIME_IMAGE_CONVERGENCE_RUN_ID": "unit-test-run",
            "RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA": "deadbeef" * 8,
            "RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT": "kind-threadforge",
            "CLUSTER_IMAGE_MAP_PATH": str(cluster_map_path),
            "THREADFORGE_REGISTRY_USER": "threadforge",
            "THREADFORGE_REGISTRY_PASSWORD": "threadforge-dev-password",
        }
    )

    return env, call_log, cache_file, cluster_map_path


def _run_script(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    script = REPO_ROOT / "scripts" / "proof" / "pin_runtime_images.sh"
    return subprocess.run([str(script)], cwd=REPO_ROOT, env=env, capture_output=True, text=True, check=True)


def _seed_partial_cache(cache_file: Path, cluster_map_path: Path, env: dict[str, str]) -> None:
    cache_file.write_text(
        json.dumps(
            {
                "run_id": env["RUNTIME_IMAGE_CONVERGENCE_RUN_ID"],
                "source_sha": env["RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA"],
                "cluster_context": env["RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT"],
                "state_fingerprint": _state_fingerprint(cluster_map_path),
                "converged_refs": [
                    "registry.threadforge.local:30500/coredns/coredns@sha256:ba9e70dbdf0ff8a77ea63451bb1241d08819471730fe7a35a218a8db2ef7890c",
                    "registry.threadforge.local:30500/etcd@sha256:22f892d7672adc0b9c86df67792afdb8b2dc08880f49f669eaaa59c47d7908c2",
                ],
                "converged_digests": [
                    "sha256:ba9e70dbdf0ff8a77ea63451bb1241d08819471730fe7a35a218a8db2ef7890c",
                    "sha256:22f892d7672adc0b9c86df67792afdb8b2dc08880f49f669eaaa59c47d7908c2",
                ],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def test_runtime_image_pinning_uses_run_local_cache(tmp_path: Path) -> None:
    env, call_log, cache_file, _cluster_map = _make_harness(tmp_path)

    first = _run_script(env)
    first_calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" in first_calls
    assert "cosign sign" in first_calls
    assert "cosign verify" in first_calls
    assert "INPUT_IMAGE_REFS=14" in first.stdout
    assert "UNIQUE_CANONICAL_REFS=14" in first.stdout
    assert "UNIQUE_DIGESTS=11" in first.stdout
    assert "SKOPEO_CALLS=11" in first.stdout
    assert "SIGNATURE_SIGN_CALLS=7" in first.stdout
    assert "SIGNATURE_VERIFICATIONS=7" in first.stdout
    assert "SIGN_CALLS=7" in first.stdout
    assert "VERIFY_CALLS=7" in first.stdout
    assert "CACHE_HITS=3" in first.stdout
    assert "MUTATING_RECONCILIATIONS=0" in first.stdout
    assert cache_file.exists()

    call_log.write_text("", encoding="utf-8")

    second = _run_script(env)
    second_calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" not in second_calls
    assert "cosign sign" not in second_calls
    assert "cosign verify" not in second_calls
    assert "INPUT_IMAGE_REFS=14" in second.stdout
    assert "SKOPEO_CALLS=0" in second.stdout
    assert "SIGN_CALLS=0" in second.stdout
    assert "VERIFY_CALLS=0" in second.stdout
    assert "CACHE_HITS=14" in second.stdout
    assert cache_file.exists()


def test_runtime_image_pinning_invalidates_when_cluster_state_changes(tmp_path: Path) -> None:
    env, call_log, cache_file, cluster_map_path = _make_harness(tmp_path)

    _run_script(env)
    call_log.write_text("", encoding="utf-8")

    cluster_map = json.loads(cluster_map_path.read_text(encoding="utf-8"))
    mutated_key = next(iter(cluster_map))
    cluster_map[mutated_key] = f"{cluster_map[mutated_key]}-mutated"
    cluster_map_path.write_text(json.dumps(cluster_map, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    second = _run_script(env)
    second_calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" in second_calls
    assert "cosign sign" in second_calls
    assert "cosign verify" in second_calls
    assert "CACHE_HITS=3" in second.stdout
    assert "SKOPEO_CALLS=11" in second.stdout
    assert "SIGN_CALLS=0" not in second.stdout
    assert "VERIFY_CALLS=0" not in second.stdout
    assert "MUTATING_RECONCILIATIONS=0" in second.stdout
    cache = json.loads(cache_file.read_text(encoding="utf-8"))
    assert cache["state_fingerprint"] == _state_fingerprint(cluster_map_path)


@pytest.mark.parametrize(
    ("env_key", "replacement"),
    [
        ("RUNTIME_IMAGE_CONVERGENCE_RUN_ID", "unit-test-run-2"),
        ("RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA", "cafebabe" * 8),
        ("RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT", "kind-alt"),
    ],
)
def test_runtime_image_pinning_recomputes_for_cache_identity_mismatches(
    tmp_path: Path, env_key: str, replacement: str
) -> None:
    env, call_log, _cache_file, _cluster_map_path = _make_harness(tmp_path)

    _run_script(env)
    call_log.write_text("", encoding="utf-8")

    env[env_key] = replacement
    second = _run_script(env)
    second_calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" in second_calls
    assert "cosign sign" in second_calls
    assert "cosign verify" in second_calls
    assert "CACHE_HITS=3" in second.stdout
    assert "SKOPEO_CALLS=11" in second.stdout
    assert "SIGN_CALLS=7" in second.stdout
    assert "VERIFY_CALLS=7" in second.stdout


def test_runtime_image_pinning_falls_back_on_malformed_cache(tmp_path: Path) -> None:
    env, call_log, cache_file, _cluster_map_path = _make_harness(tmp_path)
    cache_file.write_text("not-json", encoding="utf-8")

    result = _run_script(env)
    calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" in calls
    assert "cosign sign" in calls
    assert "cosign verify" in calls
    assert "CACHE_HITS=3" in result.stdout
    assert "SKOPEO_CALLS=11" in result.stdout
    assert "SIGN_CALLS=7" in result.stdout
    assert "VERIFY_CALLS=7" in result.stdout


def test_runtime_image_pinning_uses_partial_cache_for_converged_subset(tmp_path: Path) -> None:
    env, call_log, cache_file, cluster_map_path = _make_harness(tmp_path)
    _seed_partial_cache(cache_file, cluster_map_path, env)

    result = _run_script(env)
    calls = call_log.read_text(encoding="utf-8")
    assert "skopeo inspect" in calls
    assert "cosign sign" in calls
    assert "cosign verify" in calls
    assert "CACHE_HITS=14" not in result.stdout
    assert "SKOPEO_CALLS=0" not in result.stdout
