from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load_module(module_path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_same_namespace_allowed() -> None:
    module = _load_module(Path("platform/runtime/security/tenant_model.py"), "tenant_model")
    module.validate_tenant_access(
        "spiffe://threadforge/ns/threadforge-test/sa/test-client",
        "threadforge-test",
    )


def test_cross_namespace_denied() -> None:
    module = _load_module(Path("platform/runtime/security/tenant_model.py"), "tenant_model")
    try:
        module.validate_tenant_access(
            "spiffe://threadforge/ns/threadforge-test/sa/test-client",
            "observability",
        )
    except module.TenantIsolationError:
        return
    raise AssertionError("expected TenantIsolationError for cross-namespace access")
