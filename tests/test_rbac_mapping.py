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


def test_resolve_role_known_identity() -> None:
    module = _load_module(
        Path("platform/runtime/security/rbac_mapping.py"),
        "rbac_mapping",
    )
    role = module.resolve_role("spiffe://threadforge/ns/threadforge-test/sa/test-client")
    assert role == "test-client"


def test_resolve_role_unknown_identity_raises() -> None:
    module = _load_module(
        Path("platform/runtime/security/rbac_mapping.py"),
        "rbac_mapping",
    )
    try:
        module.resolve_role("spiffe://threadforge/ns/threadforge-test/sa/unmapped")
    except module.RBACResolutionError:
        return
    raise AssertionError("expected RBACResolutionError for unknown identity")
