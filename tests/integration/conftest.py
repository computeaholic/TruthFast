"""Configuration for integration tests.

This conftest file marks all tests in this directory as integration tests,
allowing them to be filtered with `-m "not integration"`.
"""

import pytest


def pytest_configure(config):
    """Register integration marker."""
    config.addinivalue_line("markers", "integration: mark test as integration")


def pytest_collection_modifyitems(items):
    """Mark all tests in integration/ with integration marker."""
    for item in items:
        if "integration" in str(item.fspath):
            item.add_marker(pytest.mark.integration)
