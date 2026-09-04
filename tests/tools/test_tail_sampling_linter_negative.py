import pytest

from tools.dev import tail_sampling_linter as linter

pytestmark = pytest.mark.unit


def test_bad_fractional_is_invalid():
    errs = linter.check_file("tests/tail_sampling_vectors/invalid/bad_fractional.yaml")
    assert errs and isinstance(errs, list)
