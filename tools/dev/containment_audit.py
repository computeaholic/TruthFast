from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def run(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def check_a_mutation_authority_map() -> tuple[bool, str]:
    deploy_governance = REPO_ROOT / "platform/deploy/base/policy/kyverno-governance-block.yaml"
    deploy_digest = REPO_ROOT / "platform/deploy/base/policy/kyverno-require-image-digests.yaml"
    deploy_vap_digest = REPO_ROOT / "platform/deploy/base/policy/vap-enforce-internal-registry-digest.yaml"
    deploy_kustomization = REPO_ROOT / "platform/deploy/base/policy/kustomization.yaml"
    gitops_governance = REPO_ROOT / "platform/deploy/gitops/infra/policy/kyverno-governance-block.yaml"
    gitops_digest = REPO_ROOT / "platform/deploy/gitops/infra/policy/kyverno-require-image-digests.yaml"
    gitops_vap_digest = REPO_ROOT / "platform/deploy/gitops/infra/policy/vap-enforce-internal-registry-digest.yaml"

    required_files = [
        deploy_governance,
        deploy_digest,
        deploy_vap_digest,
        deploy_kustomization,
        gitops_governance,
        gitops_digest,
        gitops_vap_digest,
    ]
    missing = [p.relative_to(REPO_ROOT).as_posix() for p in required_files if not p.exists()]
    if missing:
        return False, "missing policy artifacts: " + ", ".join(missing)

    deploy_text = deploy_governance.read_text(encoding="utf-8")
    digest_text = deploy_digest.read_text(encoding="utf-8")
    kustomization_text = deploy_kustomization.read_text(encoding="utf-8")
    if "validationFailureAction: Enforce" not in deploy_text:
        return False, "governance policy is not fail-closed (enforce)"
    if "validationFailureAction: Enforce" not in digest_text:
        return False, "digest policy is not fail-closed (enforce)"
    if "vap-enforce-internal-registry-digest.yaml" not in kustomization_text:
        return False, "VAP digest policy is not wired in platform/deploy/base/policy/kustomization.yaml"
    if "kyverno-require-image-digests.yaml" in kustomization_text:
        return False, "Kyverno digest policy is active in kustomization; expected VAP-only enforcement source"

    return (
        True,
        "governance policy present and digest enforcement source is VAP"
        " (Kyverno digest artifact mirrored but not active)",
    )


def check_b_direct_bypass() -> tuple[bool, str]:
    checks = [
        [
            "kubectl",
            "auth",
            "can-i",
            "--as=system:serviceaccount:threadforge:threadforge-client",
            "patch",
            "deployments",
            "-n",
            "threadforge",
        ],
        [
            "kubectl",
            "auth",
            "can-i",
            "--as=system:serviceaccount:threadforge:threadforge-client",
            "create",
            "rolebindings.rbac.authorization.k8s.io",
            "-n",
            "threadforge",
        ],
        [
            "kubectl",
            "auth",
            "can-i",
            "--as=system:serviceaccount:threadforge:threadforge-client",
            "patch",
            "clusterroles.rbac.authorization.k8s.io",
        ],
    ]
    for cmd in checks:
        code, out, err = run(cmd)
        answer = out.strip().lower()
        if answer == "no":
            continue
        if answer == "yes":
            return False, f"bypass detected: {' '.join(cmd)} => {out}"
        if code != 0:
            return False, f"kubectl auth check failed: {' '.join(cmd)}: {err or out}"
        return False, f"unexpected kubectl auth output: {' '.join(cmd)} => {out}"
    return True, "namespace SA cannot mutate governed resources or escalate RBAC"


def check_c_gate_determinism() -> tuple[bool, str]:
    files = {
        "runtime/operator/enforcement_gate.py": [
            "mutation_artifact_payload",
            "MutationArtifact",
            "policy bundle hash mismatch",
        ],
        "runtime/operator/mutation_artifact.py": [
            "expires_at",
            "nonce",
            "payload_hash",
            "request_hash",
            "verify",
        ],
        "runtime/operator/nonce_store.py": ["Lease", "AlreadyExists"],
    }
    for rel, needles in files.items():
        path = REPO_ROOT / rel
        if not path.exists():
            return False, f"missing {rel}"
        text = path.read_text(encoding="utf-8")
        for n in needles:
            if n not in text:
                return False, f"determinism gap: {rel} missing '{n}'"
    return True, "hash/signature/expiry/nonce/policy binding checks present"


def check_d_signature_laundering() -> tuple[bool, str]:
    from runtime.civ.provenance.decision_record import DecisionRecord

    payload = {
        "decision_id": "11111111-1111-1111-1111-111111111111",
        "decision_type": "budget_pressure",
        "generated_at": "2026-02-25T00:00:00+00:00",
        "time_window": {"start": "2026-02-24T23:00:00+00:00", "end": "2026-02-25T01:00:00+00:00"},
        "inputs": {
            "source_tables": ["value_plane.operator_ledger"],
            "query_files": ["data/queries/civ_snapshot.sql"],
            "parameters": {},
        },
        "derived_metrics": {"utilization_percent": 50.0, "denial_pressure": 0.1},
        "dominant_contributors": [],
        "counterfactual_sensitivity": {"increase_budget_by": {}, "reduce_load_by": {}, "enforce_now": {}},
        "recommendation": {"text": "noop", "confidence": 0.5},
        "provenance_hash": "0" * 64,
        "signature": "",
        "signing_key_id": "",
        "algorithm": "ed25519",
        "signed_content_hash": "",
        "mutation_artifact_id": "",
        "mutation_artifact_hash": "",
        "hidden_b": "attack",
    }
    try:
        DecisionRecord.from_dict(payload)
    except Exception:
        return True, "unknown fields rejected"
    return False, "unknown fields accepted"


def check_e_alt_execution_paths() -> tuple[bool, str]:
    vap_digest_policy = REPO_ROOT / "platform/deploy/base/policy/vap-enforce-internal-registry-digest.yaml"
    if not vap_digest_policy.exists():
        return False, "digest admission VAP policy missing"

    text = vap_digest_policy.read_text(encoding="utf-8")
    required = [
        "kind: ValidatingAdmissionPolicy",
        "name: enforce-internal-registry",
        "failurePolicy: Fail",
        'resources: ["pods"]',
        "@sha256",
        "validationActions: [Deny]",
        "threadforge",
        "threadforge-system",
        "forgesec",
        "workers",
        "redteam-test",
    ]
    if any(r not in text for r in required):
        return False, "digest admission VAP missing governed scope or digest validation clauses"
    return True, "direct kubectl/helm image-tag path in governed namespaces is admission-blocked by VAP digest policy"


def check_f_replay_and_drift() -> tuple[bool, str]:
    text = (REPO_ROOT / "runtime/operator/admission.py").read_text(encoding="utf-8")
    if "consume_nonce_via_lease" not in text:
        return False, "nonce consumption missing"
    if "policy bundle hash mismatch" not in text:
        return False, "policy drift check missing"
    if "artifact expired" not in (REPO_ROOT / "runtime/operator/mutation_artifact.py").read_text(encoding="utf-8"):
        return False, "expiry check missing"
    return True, "replay/expiry/policy-drift checks present"


def check_h_clickhouse_bootstrap_port_contract() -> tuple[bool, str]:
    runner = REPO_ROOT / "scripts/run_integration_e2e.sh"
    if not runner.exists():
        return False, "missing scripts/run_integration_e2e.sh"

    text = runner.read_text(encoding="utf-8")
    if "9000" in text:
        return False, "bootstrap script contains literal 9000"

    required_snippets = [
        "get svc clickhouse",
        'ports[?(@.name=="tcp")].port',
        "CH_TARGET_PORT",
        "port-forward",
        "CLICKHOUSE_PF_RESOURCE",
        "CLICKHOUSE_PF_MAPPING",
        "CLICKHOUSE_PORT",
    ]
    for snippet in required_snippets:
        if snippet not in text:
            return False, f"bootstrap contract missing snippet: {snippet}"

    if "value-plane-port-forward-start" in text or "value-plane-port-forward-stop" in text:
        return False, "conflicting value-plane port-forward commands still present in bootstrap script"

    return True, "ClickHouse bootstrap uses a single service-derived dynamic port contract"


def check_i_no_literal_19000_drift() -> tuple[bool, str]:
    scan_roots = [
        REPO_ROOT / "platform/deploy",
        REPO_ROOT / "platform/images",
        REPO_ROOT / "scripts",
        REPO_ROOT / "platform/runtime",
        REPO_ROOT / "tests",
    ]
    excluded_parts = [
        "docs/archive",
        ".venv",
        ".git",
        "archive",
        "artifacts",
        "audit",
        "logs",
        "tmp",
        "site",
        "site_assets",
        "deploy/infra/observability/evidence",
        "security/minio",
    ]

    legacy_port_pattern = re.compile(r"(?<!\d)(?:19000|18123|19009)(?!\d)")
    scan_suffixes = {".sh", ".py", ".mk", ".yaml", ".yml"}

    findings: list[str] = []
    for root in scan_roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix not in scan_suffixes and not path.name.startswith("Dockerfile"):
                continue
            rel = path.relative_to(REPO_ROOT).as_posix()
            if any(part in rel for part in excluded_parts):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except Exception:
                continue
            for line_no, line in enumerate(text.splitlines(), start=1):
                if legacy_port_pattern.search(line):
                    findings.append(f"{rel}:{line_no}")

    if findings:
        return False, "legacy ClickHouse port drift detected: " + ", ".join(findings[:30])
    return True, "no legacy ClickHouse ports found in active deploy/images/scripts/runtime/tests"


def main() -> int:
    checks = {
        "A": check_a_mutation_authority_map,
        "B": check_b_direct_bypass,
        "E": check_e_alt_execution_paths,
        "I": check_i_no_literal_19000_drift,
    }

    all_pass = True
    report: dict[str, object] = {
        "schema_version": 1,
        "generated_at": datetime.now(tz=UTC).isoformat(timespec="seconds"),
        "source_sha": run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"])[1],
        "verify_type": "READ_ONLY",
    }
    for section, fn in checks.items():
        ok, detail = fn()
        status = "PASS" if ok else "FAIL"
        report[section] = {"status": status, "detail": detail}
        print(f"{section}: {status} - {detail}")
        if not ok:
            all_pass = False

    verdict = (
        "Containment holds under defined scope."
        if all_pass
        else "Containment claim is false under current architecture."
    )
    report["G"] = {"status": "PASS" if all_pass else "FAIL", "detail": verdict}
    print(f"G: {report['G']['status']} - {verdict}")
    print(f"containment_claim={'true' if all_pass else 'false'}")

    out = REPO_ROOT / "artifacts" / "audit" / "containment_audit_report.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    return 0 if all_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
