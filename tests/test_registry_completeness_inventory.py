import importlib.util
import json
import sys
from pathlib import Path

import pytest


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "verify" / "registry_completeness.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("registry_completeness", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_canonical_digest_inventory_collapses_alias_refs_once() -> None:
    module = _load_module()
    digest_a = "sha256:" + "a" * 64
    digest_b = "sha256:" + "b" * 64
    refs_by_source = {
        "expected": [
            f"registry.threadforge.local:30500/team/app@{digest_a}",
            f"registry.threadforge.local:30500/team/app-alias@{digest_a}",
            f"registry.threadforge.local:30500/team/worker@{digest_b}",
        ],
        "runtime": [],
        "allowed": [],
    }

    canonical_refs, errors = module.build_canonical_refs(
        refs_by_source,
        pin_map={},
        allowed_prefix="registry.threadforge.local:30500/",
    )

    assert errors == []
    assert len(canonical_refs) == 3

    digest_groups = module.build_digest_groups(canonical_refs)
    assert len(digest_groups) == 2
    assert {group.digest for group in digest_groups} == {digest_a, digest_b}
    alias_group = next(group for group in digest_groups if group.digest == digest_a)
    assert alias_group.representative_ref == f"registry.threadforge.local:30500/team/app-alias@{digest_a}"
    assert len(alias_group.canonical_refs) == 2
    assert len(alias_group.raw_refs) == 2


def test_digest_inventory_rejects_mutable_tags_before_digests() -> None:
    module = _load_module()
    refs_by_source = {
        "expected": ["registry.threadforge.local:30500/team/app:latest@sha256:" + "a" * 64],
        "runtime": [],
        "allowed": [],
    }

    canonical_refs, errors = module.build_canonical_refs(
        refs_by_source,
        pin_map={},
        allowed_prefix="registry.threadforge.local:30500/",
    )

    assert canonical_refs == []
    assert errors and "mutable tag" in errors[0]


def test_sign_verification_budget_covers_helper_retries() -> None:
    module = _load_module()

    assert module.sign_verification_budget_seconds(
        skopeo_timeout=25,
        cosign_timeout=180,
        cosign_retries=5,
        retry_interval=2,
    ) == 934


def test_registry_completeness_overwrites_stale_inventory_with_current_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    module = _load_module()
    expected = tmp_path / "expected.txt"
    runtime = tmp_path / "runtime.txt"
    allowed = tmp_path / "allowed.txt"
    for path in (expected, runtime, allowed):
        path.write_text("registry.threadforge.local:30500/team/app@sha256:" + "a" * 64 + "\n", encoding="utf-8")

    output_dir = tmp_path / "out"
    output_dir.mkdir()
    stale_inventory = output_dir / "registry_completeness_inventory.json"
    stale_inventory.write_text(
        json.dumps(
            {
                "status": "PASS",
                "plan": {"started_epoch": 1.0, "finished_epoch": 2.0},
                "results": [{"digest": "sha256:" + "f" * 64}],
            }
        ),
        encoding="utf-8",
    )

    digest = "sha256:" + "a" * 64
    canonical_ref = f"registry.threadforge.local:30500/team/app@{digest}"
    canonical_refs = [
        module.CanonicalRef(
            raw_ref=canonical_ref,
            canonical_ref=canonical_ref,
            digest=digest,
            source="expected",
        )
    ]
    digest_groups = [
        module.DigestGroup(
            digest=digest,
            representative_ref=canonical_ref,
            canonical_refs=(canonical_ref,),
            raw_refs=(canonical_ref,),
            sources=("expected",),
        )
    ]

    monkeypatch.setattr(module, "build_canonical_refs", lambda *args, **kwargs: (canonical_refs, []))
    monkeypatch.setattr(module, "build_digest_groups", lambda canonical_refs: digest_groups)
    monkeypatch.setattr(
        module,
        "verify_digest_group",
        lambda digest_group, **kwargs: {
            "digest": digest_group.digest,
            "representative_ref": digest_group.representative_ref,
            "canonical_refs": list(digest_group.canonical_refs),
            "raw_refs": list(digest_group.raw_refs),
            "sources": list(digest_group.sources),
            "resolve_attempts": 1,
            "resolve_rc": 0,
            "sign_rc": 0,
            "probe_attempts": 1,
            "probe_http_code": "200",
        },
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "registry_completeness.py",
            "--expected",
            str(expected),
            "--runtime",
            str(runtime),
            "--allowed",
            str(allowed),
            "--pin-map",
            str(tmp_path / "pin-map.json"),
            "--output-dir",
            str(output_dir),
            "--probe-namespace",
            "observability",
            "--probe-pod",
            "probe-pod",
            "--probe-container",
            "probe-container",
            "--probe-mount-path",
            "/etc/ca.crt",
            "--registry-host",
            "registry.threadforge.local",
            "--registry-port",
            "30500",
            "--registry-user",
            "threadforge",
            "--registry-password",
            "threadforge-dev-password",
            "--registry-ca-cert",
            str(tmp_path / "ca.crt"),
            "--sign-script",
            str(tmp_path / "sign_images.sh"),
            "--max-concurrency",
            "1",
        ],
    )
    (tmp_path / "ca.crt").write_text("ca", encoding="utf-8")
    (tmp_path / "sign_images.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")

    rc = module.main()
    assert rc == 0

    inventory = json.loads(stale_inventory.read_text(encoding="utf-8"))
    assert inventory["status"] == "PASS"
    assert inventory["plan"]["started_epoch"] != 1.0
    assert inventory["plan"]["finished_epoch"] >= inventory["plan"]["started_epoch"]
    assert inventory["results"]
    assert inventory["results"][0]["digest"] == digest
