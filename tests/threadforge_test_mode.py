from __future__ import annotations

import os

import pytest

THREADFORGE_TEST_MODE = os.getenv("THREADFORGE_TEST_MODE", "local")
ALLOWED_TEST_MODES = {"local", "cluster", "full"}
CLUSTER_TEST_MODES = {"cluster", "full"}
_skip_count = 0


def get_test_mode() -> str:
    return THREADFORGE_TEST_MODE


def validate_test_mode() -> None:
    if THREADFORGE_TEST_MODE not in ALLOWED_TEST_MODES:
        raise pytest.UsageError("THREADFORGE_TEST_MODE must be one of: local, cluster, full")


def reset_skip_count() -> None:
    global _skip_count

    _skip_count = 0


def increment_skip_count() -> None:
    global _skip_count

    _skip_count += 1


def get_skip_count() -> int:
    return _skip_count


def require_cluster_mode() -> None:
    if get_test_mode() not in CLUSTER_TEST_MODES:
        pytest.skip(
            "SKIP: not applicable to the local test profile; native Kind integration runs in "
            "THREADFORGE_TEST_MODE=cluster or full"
        )


def skip_in_local_mode(reason: str, *, failure_reason: str | None = None) -> None:
    if get_test_mode() == "local":
        pytest.skip(reason)
    pytest.fail(failure_reason or reason, pytrace=False)


def require_env(name: str) -> str:
    value = os.getenv(name)
    if value:
        return value
    pytest.fail(f"{name} is required in {get_test_mode()} mode", pytrace=False)


def require_optional_dependency(module_name: str, reason: str):
    top_level_module = module_name.split(".", maxsplit=1)[0]
    try:
        return __import__(module_name, fromlist=[top_level_module])
    except ModuleNotFoundError as exc:
        if exc.name != top_level_module:
            raise
        skip_in_local_mode(
            reason,
            failure_reason=(f"Optional runtime dependency '{top_level_module}' is required in {get_test_mode()} mode"),
        )
