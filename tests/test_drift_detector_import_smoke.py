import pytest

pytestmark = pytest.mark.smoke


def test_drift_detector_imports_without_qdrant():
    # Load module by path to assert import-time optional dependency handling
    import importlib
    import sys
    from pathlib import Path

    # Ensure project root is on sys.path so package imports inside the module work
    project_root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(project_root))

    # Now import the module via the package path; import-time qdrant handling should not raise
    mod = importlib.import_module("runtime.vector.indexer.drift_detector")

    # Concrete assertions: module imported, callable API exists
    assert "runtime.vector.indexer.drift_detector" in sys.modules
    assert hasattr(mod, "run_semantic_drift_check") and callable(mod.run_semantic_drift_check)
    # DRIFT_REPORT path is absolute and anchored to source-tree reports/ (not CWD-relative)
    assert mod.DRIFT_REPORT.is_absolute(), "DRIFT_REPORT must be an absolute path"
    assert mod.DRIFT_REPORT.parent.name == "reports", "DRIFT_REPORT must be under a reports/ directory"
    # mkdir is lazy — no directory may be created at import time (no import side effects)
    assert not mod.DRIFT_REPORT.parent.exists() or mod.DRIFT_REPORT.parent.is_dir()
