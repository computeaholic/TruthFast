import pytest
from pathlib import Path


def test_no_test_aas_dirs_at_root():
    """Fail if any top-level directory starts with 'test_aas'.

    This prevents tests from writing artifacts into the repository root.
    Tests should use `artifacts/` or pytest `tmp_path`/`tempfile`.
    """
    root = Path.cwd()
    for entry in root.iterdir():
        if entry.is_dir() and entry.name.startswith("test_aas"):
            pytest.fail(f"Forbidden top-level directory present: {entry.name}")
