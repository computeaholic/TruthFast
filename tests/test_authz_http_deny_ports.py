from pathlib import Path
import re

import pytest
import yaml

pytestmark = pytest.mark.unit

HTTP_ATTRIBUTE_KEYS = {"hosts", "methods", "paths", "headers"}
ROOT = Path(__file__).resolve().parent.parent
SCAN_SUFFIXES = {".yaml", ".yml", ".sh"}


def _iter_authz_documents(path: Path):
    text = path.read_text()
    if path.suffix in {".yaml", ".yml"}:
        try:
            documents = list(yaml.safe_load_all(text))
        except yaml.YAMLError:
            return
        for document in documents:
            if isinstance(document, dict) and document.get("kind") == "AuthorizationPolicy":
                yield document
        return

    pattern = re.compile(r"(^apiVersion:\s*security\.istio\.io/.*?)(?=^YAML\s*$|^EOF\s*$|\Z)", re.MULTILINE | re.DOTALL)
    for match in pattern.finditer(text):
        try:
            document = yaml.safe_load(match.group(1))
        except yaml.YAMLError:
            continue
        if isinstance(document, dict) and document.get("kind") == "AuthorizationPolicy":
            yield document


def _find_deny_http_rules_missing_ports(document: dict):
    if document.get("spec", {}).get("action", "ALLOW") != "DENY":
        return []

    violations = []
    for rule_index, rule in enumerate(document.get("spec", {}).get("rules", [])):
        for to_index, to_clause in enumerate(rule.get("to", [])):
            operation = to_clause.get("operation", {})
            if not isinstance(operation, dict):
                continue
            if not HTTP_ATTRIBUTE_KEYS.intersection(operation):
                continue
            if operation.get("ports"):
                continue
            violations.append((rule_index, to_index, sorted(HTTP_ATTRIBUTE_KEYS.intersection(operation))))
    return violations


def test_deny_http_authz_rules_are_port_scoped():
    violations = []
    for path in ROOT.rglob("*"):
        if path.suffix not in SCAN_SUFFIXES or not path.is_file():
            continue
        for document in _iter_authz_documents(path):
            for rule_index, to_index, http_keys in _find_deny_http_rules_missing_ports(document):
                violation = " ".join(
                    [
                        f"{path.relative_to(ROOT)}::{document['metadata']['name']}",
                        f"rule={rule_index}",
                        f"to={to_index}",
                        f"http_keys={','.join(http_keys)}",
                    ]
                )
                violations.append(violation)

    assert (
        not violations
    ), "DENY AuthorizationPolicy rules using HTTP attributes must declare explicit ports:\n" + "\n".join(violations)
