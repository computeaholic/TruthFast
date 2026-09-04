import os
import sys

import pytest

# Ensure repo root is on sys.path so 'tools' package is importable during tests
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from tools.dev.tail_sampling_linter import check_file, validate_policy

pytestmark = pytest.mark.unit


def test_valid_numeric_min_only():
    p = {"type": "numeric_attribute", "numeric_attribute": {"key": "x", "min_value": 1}}
    errs = validate_policy(p)
    assert errs == []


def test_valid_numeric_min_max():
    p = {"type": "numeric_attribute", "numeric_attribute": {"key": "x", "min_value": 0, "max_value": 10}}
    errs = validate_policy(p)
    assert errs == []


def test_fractional_min_value_rejected():
    p = {"type": "numeric_attribute", "numeric_attribute": {"key": "x", "min_value": 0.5}}
    errs = validate_policy(p)
    assert any("must be an integer" in e for e in errs)


def test_missing_min_max_rejected():
    p = {"type": "numeric_attribute", "numeric_attribute": {"key": "x"}}
    errs = validate_policy(p)
    assert any("must set at least one" in e for e in errs)


def test_probabilistic_range():
    p = {"type": "probabilistic", "probabilistic": {"sampling_percentage": 50}}
    errs = validate_policy(p)
    assert errs == []


def test_probabilistic_out_of_range():
    p = {"type": "probabilistic", "probabilistic": {"sampling_percentage": 101}}
    errs = validate_policy(p)
    assert any("in range" in e for e in errs)


def test_string_attribute_values():
    p = {"type": "string_attribute", "string_attribute": {"key": "cat", "values": ["storage"]}}
    errs = validate_policy(p)
    assert errs == []


def test_cli_check_file_bad(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text(
        "policies:\n"
        "  - type: numeric_attribute\n"
        "    numeric_attribute:\n"
        "      key: x\n"
        "      min_value: 0.5\n"
    )
    out = check_file(str(bad))
    joined = "\n".join(out)
    assert ("fractional" in joined) or ("integer" in joined)


def test_cli_check_no_policy(tmp_path):
    f = tmp_path / "nopolicy.yaml"
    f.write_text("foo: bar\n")
    out = check_file(str(f))
    assert any("no policy blocks found" in s for s in out)
