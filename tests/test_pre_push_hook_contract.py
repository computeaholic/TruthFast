from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_tracked_pre_push_hook_blocks_main_and_uses_repo_python_contract() -> None:
    hook = _read(".githooks/pre-push")

    assert 'exit 1' in hook
    assert '.venv/bin/python' in hook
    assert 'VIRTUAL_ENV/bin/python' in hook
    assert 'make docs-verify' in hook
    assert 'THREADFORGE_MKDOCS_SITE_DIR' in hook
    assert 'Unit tests failed — push blocked' in hook
    assert 'Docs validation failed — push blocked' in hook


def test_pre_push_unit_gate_is_explicit_and_bounded() -> None:
    hook = _read(".githooks/pre-push")

    assert 'PRE_PUSH_UNIT_TESTS=(' in hook
    assert 'THREADFORGE_PRE_PUSH_TEST_TIMEOUT_SECONDS' in hook
    assert 'timeout --foreground' in hook
    assert '-m "not integration"' not in hook
