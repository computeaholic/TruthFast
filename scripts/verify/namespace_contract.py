#!/usr/bin/env python3
"""Static namespace-contract validator for canonical native bootstrap."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BOOTSTRAP = REPO_ROOT / "scripts" / "infra" / "bootstrap.sh"
DEFAULT_CONVERGED = REPO_ROOT / "scripts" / "verify" / "verify_bootstrap_converged.sh"

CERT_MANAGER_NAMESPACE_MARKER = (
    "kubectl create namespace cert-manager --dry-run=client -o yaml | "
    "apply_manifest_from_stdin >/dev/null"
)
SPIRE_SYSTEM_NAMESPACE_MARKER = (
    "kubectl get ns spire-system >/dev/null 2>&1 || kubectl create ns "
    "spire-system"
)
ISTIO_SYSTEM_NAMESPACE_MARKER = (
    "kubectl create namespace istio-system --dry-run=client -o yaml | "
    "apply_manifest_from_stdin >/dev/null"
)
KYVERNO_NAMESPACE_MARKER = (
    "kubectl create namespace kyverno --dry-run=client -o yaml | "
    "apply_manifest_from_stdin >/dev/null"
)
KYVERNO_SECRET_MARKER = (
    "kubectl -n kyverno create secret docker-registry registry-credentials"
)
OBSERVABILITY_SECRET_MARKER = (
    "kubectl -n observability create secret docker-registry "
    "registry-credentials"
)
THREADFORGE_TEST_SECRET_MARKER = (
    "kubectl -n threadforge-test create secret docker-registry "
    "registry-credentials"
)
THREADFORGE_NAMESPACE_POSTCONDITION = (
    "kubectl get namespace threadforge-test >/dev/null 2>&1"
)
THREADFORGE_SYSTEM_PRODUCER_CALL = "publish_registry_ca_configmaps"
THREADFORGE_SYSTEM_NAMESPACE_PRODUCER = (
    "kubectl get namespace threadforge-system >/dev/null 2>&1 || "
    "kubectl create namespace threadforge-system >/dev/null"
)
THREADFORGE_SYSTEM_POSTCONDITION = (
    "kubectl get namespace threadforge-system >/dev/null 2>&1 || "
    "kubectl create namespace threadforge-system >/dev/null"
)
THREADFORGE_SYSTEM_LABEL_MARKER = (
    "kubectl label namespace threadforge-system istio-injection=enabled "
    "--overwrite >/dev/null"
)
PROOF_PURITY_FAILURE_MESSAGE = (
    "[FAIL] NAMESPACE_CONTRACT: unable to parse required namespace list "
    "from verify_bootstrap_converged.sh"
)


@dataclass(frozen=True)
class Rule:
    namespace: str
    producer_marker: str
    consumer_markers: tuple[str, ...]
    producer_postcondition_markers: tuple[str, ...]
    producer_owner: str
    expected_lifetime: str
    category: str


RULES: dict[str, Rule] = {
    "cert-manager": Rule(
        namespace="cert-manager",
        producer_marker=CERT_MANAGER_NAMESPACE_MARKER,
        consumer_markers=(
            "kubectl -n cert-manager create secret docker-registry "
            "registry-credentials",
        ),
        producer_postcondition_markers=(
            "kubectl -n cert-manager create secret docker-registry "
            "registry-credentials",
        ),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "spire-system": Rule(
        namespace="spire-system",
        producer_marker=SPIRE_SYSTEM_NAMESPACE_MARKER,
        consumer_markers=(
            "kubectl -n spire-system delete daemonset spire-agent",
            "label_namespace_injection spire-system disabled",
        ),
        producer_postcondition_markers=(
            "kubectl -n spire-system create secret docker-registry "
            "registry-credentials",
        ),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "istio-system": Rule(
        namespace="istio-system",
        producer_marker=ISTIO_SYSTEM_NAMESPACE_MARKER,
        consumer_markers=(
            "kubectl -n istio-system create secret docker-registry "
            "registry-credentials",
        ),
        producer_postcondition_markers=(
            "kubectl -n istio-system create secret docker-registry "
            "registry-credentials",
        ),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "kyverno": Rule(
        namespace="kyverno",
        producer_marker="install_kyverno_release",
        consumer_markers=("wait_for_kyverno_admission_ready", "apply_kyverno_policies"),
        producer_postcondition_markers=("kubectl -n kyverno create secret docker-registry registry-credentials",),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "observability": Rule(
        namespace="observability",
        producer_marker="# namespace-contract: observability namespace producer",
        consumer_markers=(
            "label_namespace_injection observability enabled",
            OBSERVABILITY_SECRET_MARKER,
        ),
        producer_postcondition_markers=(OBSERVABILITY_SECRET_MARKER,),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "threadforge-test": Rule(
        namespace="threadforge-test",
        producer_marker="ensure_threadforge_test_namespace",
        consumer_markers=(
            "wait_for_kyverno_admission_ready",
            "require_threadforge_test_namespace",
            THREADFORGE_TEST_SECRET_MARKER,
        ),
        producer_postcondition_markers=(THREADFORGE_NAMESPACE_POSTCONDITION,),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
    "threadforge-system": Rule(
        namespace="threadforge-system",
        producer_marker=THREADFORGE_SYSTEM_PRODUCER_CALL,
        consumer_markers=(
            "kubectl -n threadforge-system create secret docker-registry "
            "registry-credentials",
            "wait_for_workload_deployment_ready threadforge-system "
            "threadforge-notifier",
        ),
        producer_postcondition_markers=(THREADFORGE_SYSTEM_LABEL_MARKER,),
        producer_owner="bootstrap prerequisite producer",
        expected_lifetime="bootstrap-owned through validation",
        category="BOOTSTRAP_REQUIRED",
    ),
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_required_namespaces(converged_text: str) -> list[str]:
    match = re.search(r"for ns in ([^;]+); do", converged_text)
    if not match:
        raise SystemExit(PROOF_PURITY_FAILURE_MESSAGE)
    return match.group(1).split()


def line_positions(text: str, marker: str) -> list[int]:
    positions: list[int] = []
    for idx, line in enumerate(text.splitlines(), start=1):
        if line == marker:
            positions.append(idx)
    return positions


def extract_function_body(text: str, function_name: str) -> str:
    start_token = f"{function_name}() {{"
    try:
        start = text.index(start_token)
    except ValueError as exc:
        raise SystemExit(f"[FAIL] NAMESPACE_CONTRACT: missing function definition: {function_name}") from exc
    lines = text[start:].splitlines()
    body: list[str] = []
    depth = 0
    for line in lines[1:]:
        if depth == 0 and line.strip() == "}":
            break
        body.append(line)
        depth += line.count("{") - line.count("}")
    return "\n".join(body)


def first_position_after(text: str, marker: str, after_line: int) -> int | None:
    for idx, line in enumerate(text.splitlines(), start=1):
        if idx <= after_line:
            continue
        if marker in line:
            return idx
    return None


def analyze_namespace(namespace: str, bootstrap_text: str) -> dict[str, object]:
    if namespace not in RULES:
        raise SystemExit(f"[FAIL] NAMESPACE_CONTRACT: no rule defined for required namespace {namespace}")

    rule = RULES[namespace]
    producer_positions = line_positions(bootstrap_text, rule.producer_marker)
    if not producer_positions:
        return {
            "namespace": namespace,
            "category": rule.category,
            "producer": "MISSING_PRODUCER",
            "producer_line": None,
            "consumer_line": None,
            "postcondition": "MISSING",
            "violations": ["NO_PRODUCER"],
        }

    producer_line = producer_positions[0]

    consumer_line = None
    for marker in rule.consumer_markers:
        positions = line_positions(bootstrap_text, marker)
        if positions and (consumer_line is None or positions[0] < consumer_line):
            consumer_line = positions[0]

    violations: list[str] = []
    if consumer_line is not None and consumer_line < producer_line:
        violations.append("CONSUMER_BEFORE_PRODUCER")

    if namespace == "kyverno":
        function_body = extract_function_body(bootstrap_text, "install_kyverno_release")
        if KYVERNO_NAMESPACE_MARKER not in function_body:
            violations.append("UNVERIFIED_BOOTSTRAP_NAMESPACE_PRODUCER")
        if KYVERNO_SECRET_MARKER not in function_body:
            violations.append("MISSING_PRODUCER_POSTCONDITION")
    elif namespace == "threadforge-test":
        function_body = extract_function_body(bootstrap_text, "ensure_threadforge_test_namespace")
        if "# namespace-contract: threadforge-test namespace producer" not in function_body:
            violations.append("UNVERIFIED_BOOTSTRAP_NAMESPACE_PRODUCER")
        if THREADFORGE_NAMESPACE_POSTCONDITION not in function_body:
            violations.append("MISSING_PRODUCER_POSTCONDITION")
    elif namespace == "threadforge-system":
        function_body = extract_function_body(bootstrap_text, "publish_registry_ca_configmaps")
        if THREADFORGE_SYSTEM_NAMESPACE_PRODUCER not in function_body:
            violations.append("UNVERIFIED_BOOTSTRAP_NAMESPACE_PRODUCER")
        if THREADFORGE_SYSTEM_LABEL_MARKER not in function_body:
            violations.append("MISSING_PRODUCER_POSTCONDITION")
    else:
        for marker in rule.producer_postcondition_markers:
            if marker not in bootstrap_text:
                violations.append("MISSING_PRODUCER_POSTCONDITION")
                break

    return {
        "namespace": namespace,
        "category": rule.category,
        "producer": rule.producer_owner,
        "producer_line": producer_line,
        "consumer_line": consumer_line,
        "postcondition": "PASS" if "MISSING_PRODUCER_POSTCONDITION" not in violations else "FAIL",
        "violations": violations,
        "expected_lifetime": rule.expected_lifetime,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap-file", type=Path, default=DEFAULT_BOOTSTRAP)
    parser.add_argument("--converged-file", type=Path, default=DEFAULT_CONVERGED)
    args = parser.parse_args()

    bootstrap_text = read_text(args.bootstrap_file)
    converged_text = read_text(args.converged_file)
    required = parse_required_namespaces(converged_text)

    inventory = []
    matrix = []
    violations = []

    inventory.append("HOST/BUILTIN: kube-system kube-public kube-node-lease default")
    for namespace in required:
        inventory.append(f"{namespace}: {RULES[namespace].category}")
        record = analyze_namespace(namespace, bootstrap_text)
        matrix.append(
            f"{namespace}\tproducer={record['producer']}\t"
            f"producer_line={record['producer_line']}\t"
            f"consumer_line={record['consumer_line']}\t"
            f"postcondition={record['postcondition']}"
        )
        for violation in record["violations"]:
            violations.append(f"{namespace}:{violation}")

    print("NAMESPACE_INVENTORY=")
    for item in inventory:
        print(f"  {item}")
    print("NAMESPACE_CONTRACT_MATRIX=")
    for item in matrix:
        print(f"  {item}")

    if violations:
        print("[FAIL] NAMESPACE_CONTRACT_VIOLATIONS:")
        for item in violations:
            print(f"  {item}")
        return 2

    print("[PASS] namespace contract verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
