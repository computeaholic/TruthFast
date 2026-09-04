from __future__ import annotations

import ast
from pathlib import Path


def test_canonical_runtime_has_no_orphaned_ledger_http_surface() -> None:
    app_path = Path("platform/runtime/api/app.py")
    tree = ast.parse(app_path.read_text(encoding="utf-8"))

    imported_modules = {
        node.module
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.module is not None
    }
    route_prefixes = {
        keyword.value.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "include_router"
        for keyword in node.keywords
        if keyword.arg == "prefix" and isinstance(keyword.value, ast.Constant)
    }

    assert "runtime.api.ledger_api" not in imported_modules
    assert "/ledger" not in route_prefixes
    assert not Path("platform/runtime/api/ledger_api.py").exists()


def test_canonical_runtime_creates_structured_log_parent_before_file_handler() -> None:
    app_source = Path("platform/runtime/api/app.py").read_text(encoding="utf-8")
    mkdir_offset = app_source.index("Path(APP_LOG_PATH).parent.mkdir")
    handler_offset = app_source.index("logging.FileHandler(APP_LOG_PATH)")
    assert mkdir_offset < handler_offset
