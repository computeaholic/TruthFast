from __future__ import annotations

import os

from tests.threadforge_test_mode import CLUSTER_TEST_MODES, get_skip_count, get_test_mode


def test_cluster_mode_has_no_skips(pytestconfig):
    assert getattr(pytestconfig, "_threadforge_test_mode", get_test_mode()) == get_test_mode()

    if os.getenv("THREADFORGE_TEST_MODE") in CLUSTER_TEST_MODES:
        assert (
            get_skip_count() == 0
        ), f"{get_test_mode()} mode forbids skipped tests; observed {get_skip_count()} skip(s)"
