from __future__ import annotations

import importlib.util
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "infra" / "bootstrap_preflight.py"


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _load_module():
    spec = importlib.util.spec_from_file_location("bootstrap_preflight", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_bootstrap_preflight_is_wired_into_make_and_infra_targets() -> None:
    makefile = _read("Makefile")
    infra_mk = _read("scripts/make/infra.mk")
    script = _read("scripts/infra/bootstrap_preflight.py")
    prereqs = _read("scripts/lib/check_prereqs.sh")

    assert "bootstrap: infra-bootstrap bootstrap-verify" in makefile
    assert "preflight:" in makefile
    assert "vm-preflight:" in makefile
    assert "bootstrap-preflight:" in infra_mk
    assert 'if ! $(MAKE) bootstrap-preflight >"$$preflight_log" 2>&1' in infra_mk
    assert 'cat "$$preflight_log" >&2' in infra_mk
    assert "@$(MAKE) bootstrap-preflight >/dev/null" not in infra_mk
    assert "python3 scripts/infra/bootstrap_preflight.py" in infra_mk
    assert "host_trust_prime.sh" in script
    assert "--mode\", \"verify\"" in script
    assert '"skopeo",' in script
    assert '"inspect",' in script
    assert "require_tool git" in prereqs
    assert "require_tool skopeo" in prereqs


def test_bootstrap_preflight_validates_canonical_inventory_and_external_sources() -> None:
    module = _load_module()
    inventory = module.load_inventory()
    module.verify_repo_clone()

    module.validate_inventory_entry(inventory[0])
    probes = module.registry_probe_plan(inventory)

    assert set(probes) == {"docker.io", "ghcr.io", "quay.io", "registry.k8s.io"}
    assert probes["docker.io"].startswith("docker.io/")
    assert probes["ghcr.io"].startswith("ghcr.io/")
    assert probes["quay.io"].startswith("quay.io/")
    assert probes["registry.k8s.io"].startswith("registry.k8s.io/")


def test_bootstrap_preflight_classifies_registry_probe_failures() -> None:
    module = _load_module()

    assert module.classify_registry_probe_failure("unauthorized: authentication required") == (
        "REGISTRY_AUTH_VALIDATION",
        "registry authentication required",
    )
    assert module.classify_registry_probe_failure("x509: certificate signed by unknown authority") == (
        "REGISTRY_TLS_FAILURE",
        "registry TLS verification failed",
    )
    assert module.classify_registry_probe_failure("manifest unknown") == (
        "MISSING_IMAGE",
        "registry image not found",
    )
