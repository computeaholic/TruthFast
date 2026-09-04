"""Tail-sampling static validator

This module validates OpenTelemetry tail_sampling policy blocks for common
misconfigurations that previously led to runtime evaluator panics.

Usage (CLI):
  python -m tools.tail_sampling_linter --check tests/tail_sampling_vectors

Exit code: 0 on success, 1 on validation failure or parse error.
"""

from __future__ import annotations

import argparse
import os
from typing import Any, Dict, Iterable, List

import yaml


class ValidationError(Exception):
    pass


def _is_intish(value: Any) -> bool:
    # Accept ints or floats that are whole numbers (e.g., 1.0), but reject fractional floats
    if isinstance(value, int):
        return True
    if isinstance(value, float):
        return value.is_integer()
    return False


def validate_policy(policy: Dict[str, Any]) -> List[str]:
    """Validate a single tail_sampling policy block.

    Returns a list of error strings (empty if valid).
    """
    errs: List[str] = []

    ptype = policy.get("type")
    if not ptype:
        errs.append("missing 'type' in policy")
        return errs

    if ptype == "numeric_attribute":
        na = policy.get("numeric_attribute")
        if not isinstance(na, dict):
            errs.append("numeric_attribute must be an object")
            return errs
        has_min = "min_value" in na
        has_max = "max_value" in na
        if not (has_min or has_max):
            errs.append("numeric_attribute must set at least one of 'min_value' or 'max_value'")
            return errs
        if has_min:
            mv = na["min_value"]
            if not isinstance(mv, (int, float)):
                errs.append("numeric_attribute.min_value must be a number")
            elif not _is_intish(mv):
                errs.append(f"numeric_attribute.min_value must be an integer (no fractional values): {mv}")
            elif mv < 0:
                errs.append("numeric_attribute.min_value must be >= 0")
        if has_max:
            xv = na["max_value"]
            if not isinstance(xv, (int, float)):
                errs.append("numeric_attribute.max_value must be a number")
            elif not _is_intish(xv):
                errs.append(f"numeric_attribute.max_value must be an integer (no fractional values): {xv}")
            elif xv < 0:
                errs.append("numeric_attribute.max_value must be >= 0")
        if has_min and has_max:
            try:
                if float(na["min_value"]) > float(na["max_value"]):
                    errs.append("numeric_attribute.min_value must be <= numeric_attribute.max_value")
            except Exception:
                pass

    elif ptype == "probabilistic":
        prob = policy.get("probabilistic")
        if not isinstance(prob, dict):
            errs.append("probabilistic must be an object")
            return errs
        sp = prob.get("sampling_percentage")
        if sp is None:
            errs.append("probabilistic must set 'sampling_percentage'")
        elif not isinstance(sp, (int, float)):
            errs.append("probabilistic.sampling_percentage must be a number")
        else:
            if sp < 0 or sp > 100:
                errs.append("probabilistic.sampling_percentage must be in range [0,100]")
    elif ptype == "string_attribute":
        sa = policy.get("string_attribute")
        if not isinstance(sa, dict):
            errs.append("string_attribute must be an object")
            return errs
        vals = sa.get("values")
        if not isinstance(vals, list) or len(vals) == 0:
            errs.append("string_attribute.values must be a non-empty list")
    else:
        errs.append(f"unsupported policy type: {ptype}")

    return errs


def validate_policies(policies: Iterable[Dict[str, Any]]) -> Dict[int, List[str]]:
    results: Dict[int, List[str]] = {}
    for i, p in enumerate(policies):
        errors = validate_policy(p)
        if errors:
            results[i] = errors
    return results


def load_yaml_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def find_policy_blocks(obj: Any) -> List[Dict[str, Any]]:
    # Heuristic: Search for a dict structure that contains keys 'policies' or 'tail_sampling'
    out: List[Dict[str, Any]] = []
    if isinstance(obj, dict):
        if "policies" in obj and isinstance(obj["policies"], list):
            out.extend(obj["policies"])
        for v in obj.values():
            out.extend(find_policy_blocks(v))
    elif isinstance(obj, list):
        for item in obj:
            out.extend(find_policy_blocks(item))
    return out


def check_file(path: str) -> List[str]:
    try:
        obj = load_yaml_file(path)
    except Exception as e:
        return [f"failed to parse YAML: {e}"]
    policies = find_policy_blocks(obj)
    if not policies:
        return ["no policy blocks found"]
    results = validate_policies(policies)
    out: List[str] = []
    for idx, errs in results.items():
        out.append(f"policy[{idx}]:")
        out.extend(["  " + e for e in errs])
    return out


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", nargs="+", help="Files or directories to check", required=True)
    args = parser.parse_args(argv)

    all_errors: Dict[str, List[str]] = {}
    for p in args.check:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for fn in files:
                    if fn.endswith((".yaml", ".yml")):
                        path = os.path.join(root, fn)
                        errs = check_file(path)
                        if errs:
                            all_errors[path] = errs
        else:
            errs = check_file(p)
            if errs:
                all_errors[p] = errs

    if not all_errors:
        print("Tail-sampling linter: OK")
        return 0

    print("Tail-sampling linter: FAIL")
    for path, errs in sorted(all_errors.items()):
        print(f"File: {path}")
        for err in errs:
            print(f"  {err}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
