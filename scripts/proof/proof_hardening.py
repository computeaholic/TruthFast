#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
import argparse
import fnmatch
import re
from enum import Enum
from pathlib import Path
from typing import Any


AUTHORITATIVE_KINDS = {
    "AuthorizationPolicy",
    "ClusterIssuer",
    "ClusterPolicy",
    "ConfigMap",
    "DaemonSet",
    "Deployment",
    "Gateway",
    "HTTPRoute",
    "MutatingWebhookConfiguration",
    "Namespace",
    "PeerAuthentication",
    "Service",
    "ServiceEntry",
    "StatefulSet",
    "Telemetry",
    "ValidatingWebhookConfiguration",
}

EXPECTED_KINDS = {
    "Endpoints",
    "Job",
    "Pod",
}

EXPECTED_SERVICE_FIELD_PATHS = {
    "spec.clusterIP",
    "spec.clusterIPs",
    "spec.healthCheckNodePort",
    "spec.ipFamilies",
    "spec.ipFamilyPolicy",
}


class FailureClass(Enum):
    MISSING_PREREQ = 10
    POLICY_VIOLATION = 20
    IDENTITY_FAILURE = 30
    SUPPLY_CHAIN_VIOLATION = 40
    NON_DETERMINISM = 50
    INTERNAL_ERROR = 99


def exit_with_failure(cls: FailureClass, msg: str) -> None:
    print(f"[FAIL] {cls.name}: {msg}")
    sys.exit(2)


PROJECTION_RULES_VERSION = "v1"
CANONICAL_INVENTORY_PATH = (
    Path(__file__).resolve().parents[2] / "artifacts" / "config" / "canonical_artifact_inventory.json"
)


def _load_canonical_inventory(path: Path = CANONICAL_INVENTORY_PATH) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"canonical inventory missing: {path}")
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("canonical inventory must be a JSON object")
    if data.get("projection_rules_version") != PROJECTION_RULES_VERSION:
        raise ValueError(
            "canonical inventory projection_rules_version mismatch "
            f"(expected {PROJECTION_RULES_VERSION}, got {data.get('projection_rules_version')})"
        )
    if not isinstance(data.get("canonical_required"), list) or not data["canonical_required"]:
        raise ValueError("canonical inventory must define non-empty canonical_required")
    return data


def _first_value_drift(left: Any, right: Any) -> tuple[str, Any, Any] | None:
    flat_left = _flatten(left)
    flat_right = _flatten(right)
    for key in sorted(set(flat_left) | set(flat_right)):
        v_left = flat_left.get(key)
        v_right = flat_right.get(key)
        if v_left != v_right:
            return key, v_left, v_right
    return None


def _projection_status_json(raw: str) -> dict[str, Any]:
    doc = json.loads(raw)
    keep_top = {
        "final",
        "proof_result",
        "passive_guarantees",
        "fail_class",
        "read_only_guarantees",
        "active_guarantees",
        "proof_heals_canonical_state",
        "proof_mutation_mode",
        "admission_rejection",
        "injected_images_locked",
        "ephemeral_containers_blocked",
        "exit_semantics_consistent",
        "not_evaluated_guarantees",
    }
    projected: dict[str, Any] = {k: doc.get(k) for k in sorted(keep_top)}
    guarantees = doc.get("guarantees")
    if isinstance(guarantees, dict):
        projected["guarantees"] = {
            key: (value.get("status") if isinstance(value, dict) else value)
            for key, value in sorted(guarantees.items())
        }
    blocked = doc.get("blocked_guarantees")
    if isinstance(blocked, list):
        projected["blocked_guarantees"] = sorted(str(item) for item in blocked)
    return projected


def _projection_determinism_json(raw: str) -> dict[str, Any]:
    doc = json.loads(raw)
    return {
        "consistent": doc.get("consistent"),
        "fail_class": doc.get("fail_class"),
        "method": doc.get("method"),
    }


def _projection_existing_session(raw: str) -> dict[str, Any]:
    doc = json.loads(raw)
    projected: dict[str, Any] = {
        "spire_outage": doc.get("spire_outage"),
        "existing_session": doc.get("existing_session"),
        "fresh_request_after_expiry": doc.get("fresh_request_after_expiry"),
        "reason": doc.get("reason"),
    }
    fresh = doc.get("fresh_request")
    if isinstance(fresh, dict):
        projected["fresh_request_successful"] = bool(fresh.get("successful", False))
    return projected


def _projection_workload_spire_issuer(raw: str) -> dict[str, Any]:
    doc = json.loads(raw)
    projected_workloads: list[dict[str, Any]] = []
    workloads = doc.get("workloads")
    if isinstance(workloads, list):
        for entry in workloads:
            if not isinstance(entry, dict):
                continue
            projected_workloads.append(
                {
                    "namespace": entry.get("namespace"),
                    "spiffe_id": entry.get("spiffe_id"),
                    "issuer": entry.get("issuer"),
                    "runtime_ca_serial": entry.get("runtime_ca_serial"),
                    "status": entry.get("status"),
                }
            )
    projected_workloads.sort(
        key=lambda item: (
            str(item.get("namespace", "")),
            str(item.get("spiffe_id", "")),
        )
    )
    return {
        "status": doc.get("status"),
        "active_spire_root_serial": doc.get("active_spire_root_serial"),
        "workload_count": len(projected_workloads),
        "workloads": projected_workloads,
    }


def _projection_text_lines(raw: str, patterns: tuple[str, ...]) -> list[str]:
    projected: list[str] = []
    for line in raw.splitlines():
        if any(line.startswith(prefix) for prefix in patterns):
            projected.append(line)
    return projected


def _projection_verify_norm_log(raw: str) -> list[str]:
    return _projection_text_lines(
        raw,
        (
            "CHECK=",
            "RESULT=",
            "FINAL=",
            "FINAL_VERIFICATION=",
            "READ_ONLY_GUARANTEES=",
            "PASSIVE_GUARANTEES=",
            "ACTIVE_GUARANTEES=",
            "VERIFY_SIGNATURES=",
            "VERIFY_DIGESTS=",
            "VERIFY_INVARIANTS=",
            "PROOF_PURITY_CONFIRMED",
            "RUNTIME_IDENTITY_VERIFIED=",
            "INJECTED_IMAGES_LOCKED=",
            "EPHEMERAL_CONTAINERS_BLOCKED=",
        ),
    )


def _projection_observe_log(raw: str) -> list[str]:
    normalized = re.sub(r"trace_id=[0-9a-f]+", "trace_id=<TRACE_ID>", raw)
    normalized = re.sub(r"trace_id [0-9a-f]+", "trace_id <TRACE_ID>", normalized)
    return _projection_text_lines(
        normalized,
        (
            "[observe] START",
            "[observe] PASS",
            "[observe] END",
            "CHECK=",
            "RESULT=",
        ),
    )


def _projection_status_env(raw: str) -> dict[str, str]:
    keep = {
        "final",
        "fail_class",
        "proof_result",
        "strict_mode",
        "closed_loop_status",
        "image_signing",
        "runtime_identity_verified",
        "admission_rejection",
        "injected_images_locked",
        "ephemeral_containers_blocked",
        "digest_identity_enforced",
        "exit_semantics_consistent",
        "trust_root_immutability",
        "registry_tls_trust",
        "mesh_baseline",
        "north_south_boundary",
        "east_west_isolation",
        "sidecar_enforcement",
        "service_topology",
        "rbac_resolution",
        "audit_logging",
        "tenant_isolation",
        "cert_rotation_continuity",
        "existing_session_fail_closed",
        "no_istio_ca_fallback",
        "contract_bootstrap",
        "contract_identity",
        "contract_envoy_identity",
        "contract_verify",
        "contract_observe",
        "not_evaluated_guarantees",
    }
    projected: dict[str, str] = {}
    for line in raw.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in keep:
            projected[key] = value
    return {key: projected[key] for key in sorted(projected)}


def _projection_workload_projection_continuity(raw: str) -> Any:
    doc = json.loads(raw)

    volatile_keys = {"uid", "resourceVersion", "creationTimestamp", "deletionTimestamp"}

    def _normalize(value: Any) -> Any:
        if isinstance(value, dict):
            projected: dict[str, Any] = {}
            for key, child in value.items():
                if key in volatile_keys:
                    continue
                if key == "ownerReferences" and isinstance(child, list):
                    projected[key] = [
                        _normalize(
                            {
                                sub_key: sub_value
                                for sub_key, sub_value in ref.items()
                                if sub_key not in {"uid"}
                            }
                        )
                        for ref in child
                        if isinstance(ref, dict)
                    ]
                    continue
                projected[key] = _normalize(child)
            return {key: projected[key] for key in sorted(projected)}
        if isinstance(value, list):
            return [_normalize(item) for item in value]
        return value

    return _normalize(doc)


def _project_artifact(raw_bytes: bytes, projection: str) -> Any:
    raw = raw_bytes.decode("utf-8", errors="replace")
    if projection == "json_normalized":
        return _normalize_for_determinism(json.loads(raw))
    if projection == "status_semantic":
        return _projection_status_json(raw)
    if projection == "determinism_semantic":
        return _projection_determinism_json(raw)
    if projection == "existing_session_semantic":
        return _projection_existing_session(raw)
    if projection == "workload_spire_issuer_semantic":
        return _projection_workload_spire_issuer(raw)
    if projection == "verify_norm_semantic":
        return _projection_verify_norm_log(raw)
    if projection == "observe_semantic":
        return _projection_observe_log(raw)
    if projection == "status_env_semantic":
        return _projection_status_env(raw)
    if projection == "workload_projection_continuity_semantic":
        return _projection_workload_projection_continuity(raw)
    if projection == "text":
        return raw
    raise ValueError(f"unknown projection: {projection}")


def _classify_artifact_name(name: str, inventory: dict[str, Any]) -> str:
    required_names = {
        str(entry.get("name"))
        for entry in inventory.get("canonical_required", [])
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }
    if name in required_names:
        return "canonical_required"
    for pattern in inventory.get("non_deterministic_by_design", []):
        if isinstance(pattern, str) and fnmatch.fnmatch(name, pattern):
            return "non_deterministic_by_design"
    unstable = inventory.get("unstable_collection_boundary", [])
    if isinstance(unstable, list) and name in unstable:
        return "unstable_collection_boundary"
    return "operational_optional"


def compare_with_canonical_inventory(
    run1_dir: Path,
    run2_dir: Path,
    *,
    emit_first_drift: bool,
) -> tuple[str, dict[str, Any]]:
    inventory = _load_canonical_inventory()
    d1 = run1_dir / "latest"
    d2 = run2_dir / "latest"
    if not d1.is_dir() or not d2.is_dir():
        raise FileNotFoundError("expected run directories with latest/ subdirectory")

    run1_files = {p.name for p in d1.iterdir() if p.is_file()}
    run2_files = {p.name for p in d2.iterdir() if p.is_file()}

    required_entries = [
        entry for entry in inventory.get("canonical_required", []) if isinstance(entry, dict)
    ]

    for entry in required_entries:
        name = str(entry.get("name"))
        if name not in run1_files or name not in run2_files:
            if emit_first_drift:
                print("DRIFT_CLASS=canonical_inventory_drift")
                print(f"FIRST_DRIFT_ARTIFACT={name}")
                print("FIELD=$file_presence")
                print(f"RUN1={'<present>' if name in run1_files else '<absent>'}")
                print(f"RUN2={'<present>' if name in run2_files else '<absent>'}")
            return "canonical_inventory_drift", {
                "artifact": name,
                "field": "$file_presence",
                "run1": "<present>" if name in run1_files else "<absent>",
                "run2": "<present>" if name in run2_files else "<absent>",
            }

    for entry in required_entries:
        name = str(entry.get("name"))
        projection = str(entry.get("projection"))
        proj1 = _project_artifact((d1 / name).read_bytes(), projection)
        proj2 = _project_artifact((d2 / name).read_bytes(), projection)
        drift = _first_value_drift(proj1, proj2)
        if drift is not None:
            field, v1, v2 = drift
            if emit_first_drift:
                print("DRIFT_CLASS=canonical_semantic_drift")
                print(f"FIRST_DRIFT_ARTIFACT={name}")
                print(f"FIELD={field}")
                print(f"RUN1={json.dumps(v1)}")
                print(f"RUN2={json.dumps(v2)}")
            return "canonical_semantic_drift", {
                "artifact": name,
                "field": field,
                "run1": v1,
                "run2": v2,
            }

    # At this point canonical required artifacts are stable.
    differing_operational: list[str] = []
    differing_crypto: list[str] = []
    differing_unstable_boundary: list[str] = []
    all_files = sorted(run1_files | run2_files)
    for name in all_files:
        p1 = d1 / name
        p2 = d2 / name
        same_bytes = p1.exists() and p2.exists() and p1.read_bytes() == p2.read_bytes()
        if same_bytes:
            continue
        classification = _classify_artifact_name(name, inventory)
        if classification == "non_deterministic_by_design":
            differing_crypto.append(name)
        elif classification == "unstable_collection_boundary":
            differing_unstable_boundary.append(name)
        elif classification != "canonical_required":
            differing_operational.append(name)

    if differing_operational:
        artifact = differing_operational[0]
        if emit_first_drift:
            print("DRIFT_CLASS=operational_artifact_drift")
            print(f"FIRST_DRIFT_ARTIFACT={artifact}")
            print("FIELD=$byte_diff")
            print(f"RUN1={'<present>' if (d1 / artifact).exists() else '<absent>'}")
            print(f"RUN2={'<present>' if (d2 / artifact).exists() else '<absent>'}")
        return "operational_artifact_drift", {
            "artifact": artifact,
            "field": "$byte_diff",
            "run1": "<present>" if (d1 / artifact).exists() else "<absent>",
            "run2": "<present>" if (d2 / artifact).exists() else "<absent>",
            "count": len(differing_operational),
        }

    if differing_unstable_boundary:
        artifact = differing_unstable_boundary[0]
        if emit_first_drift:
            print("DRIFT_CLASS=unstable_collection_boundary")
            print(f"FIRST_DRIFT_ARTIFACT={artifact}")
            print("FIELD=$harness_boundary")
            print(f"RUN1={'<present>' if (d1 / artifact).exists() else '<absent>'}")
            print(f"RUN2={'<present>' if (d2 / artifact).exists() else '<absent>'}")
        return "unstable_collection_boundary", {
            "artifact": artifact,
            "field": "$harness_boundary",
            "run1": "<present>" if (d1 / artifact).exists() else "<absent>",
            "run2": "<present>" if (d2 / artifact).exists() else "<absent>",
            "count": len(differing_unstable_boundary),
        }

    if differing_crypto:
        artifact = differing_crypto[0]
        if emit_first_drift:
            print("DRIFT_CLASS=non_deterministic_by_design")
            print(f"FIRST_DRIFT_ARTIFACT={artifact}")
            print("FIELD=$signature_or_rekor_variance")
            print(f"RUN1={'<present>' if (d1 / artifact).exists() else '<absent>'}")
            print(f"RUN2={'<present>' if (d2 / artifact).exists() else '<absent>'}")
        return "non_deterministic_by_design", {
            "artifact": artifact,
            "field": "$signature_or_rekor_variance",
            "run1": "<present>" if (d1 / artifact).exists() else "<absent>",
            "run2": "<present>" if (d2 / artifact).exists() else "<absent>",
            "count": len(differing_crypto),
        }

    if emit_first_drift:
        print("[PASS] first-drift-extraction: canonical semantic artifacts are identical")
    return "none", {}


def compute_final_status(
    phases_all_pass: bool,
    determinism_verified: bool,
    artifacts_verified: bool,
    blocked_guarantees: list[str],
    guarantees: dict[str, Any],
    required_failure: bool = False,
) -> str:
    if required_failure:
        return "FAIL"
    if not phases_all_pass or not determinism_verified or not artifacts_verified:
        return "FAIL"
    if blocked_guarantees:
        return "FAIL"
    if not guarantees:
        return "FAIL"
    for entry in guarantees.values():
        if not isinstance(entry, dict) or entry.get("status") != "PASS":
            return "FAIL"

    return "PASS"


def hash_artifacts(artifact_dir: Path) -> str:
    h = hashlib.sha256()
    allowed = [
        artifact_dir / "status.json",
        artifact_dir / "determinism.json",
        artifact_dir / "signed",
    ]

    for p in allowed:
        if p.is_file():
            if p.name == "status.json":
                doc = json.loads(p.read_text())
                evidence = doc.setdefault("evidence", {})
                if isinstance(evidence, dict):
                    artifacts = evidence.get("artifacts")
                    if isinstance(artifacts, dict):
                        evidence["artifacts"] = {key: "" for key in sorted(artifacts)}
                completion_record = doc.get("completion_record")
                if isinstance(completion_record, dict):
                    completion_evidence = completion_record.get("evidence")
                    if isinstance(completion_evidence, dict):
                        artifacts = completion_evidence.get("artifacts")
                        if isinstance(artifacts, dict):
                            completion_evidence["artifacts"] = {
                                key: "" for key in sorted(artifacts)
                            }
                    completion_artifacts = completion_record.get("artifacts")
                    if isinstance(completion_artifacts, dict):
                        completion_record["artifacts"] = {
                            key: "" for key in sorted(completion_artifacts)
                        }
                # Strip checked_at from guarantee entries — timestamps are
                # non-deterministic and must not affect the canonical hash.
                guarantees = doc.get("guarantees")
                if isinstance(guarantees, dict):
                    doc["guarantees"] = {
                        name: {k: v for k, v in entry.items() if k != "checked_at"}
                        if isinstance(entry, dict) else entry
                        for name, entry in guarantees.items()
                    }
                h.update(json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8"))
            elif p.name == "determinism.json":
                det = json.loads(p.read_text())
                semantic = {
                    "consistent": det.get("consistent"),
                    "fail_class": det.get("fail_class"),
                    "method": det.get("method"),
                }
                h.update(json.dumps(semantic, sort_keys=True, separators=(",", ":")).encode("utf-8"))
            else:
                h.update(p.read_bytes())
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file():
                    h.update(f.read_bytes())
    return h.hexdigest()


def write_status_atomic(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _resource_key(resource: dict[str, Any]) -> tuple[str, str, str]:
    metadata = resource.get("metadata") or {}
    return (
        str(resource.get("kind", "")),
        str(metadata.get("namespace", "")),
        str(metadata.get("name", "")),
    )


def _flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if isinstance(value, dict):
        flattened: dict[str, Any] = {}
        for key in sorted(value):
            next_prefix = f"{prefix}.{key}" if prefix else str(key)
            flattened.update(_flatten(value[key], next_prefix))
        if not flattened:
            flattened[prefix or "$"] = {}
        return flattened
    if isinstance(value, list):
        flattened = {}
        for index, item in enumerate(value):
            next_prefix = f"{prefix}[{index}]" if prefix else f"[{index}]"
            flattened.update(_flatten(item, next_prefix))
        if not flattened:
            flattened[prefix or "$"] = []
        return flattened
    return {prefix or "$": value}


def _classify_drift(kind: str, namespace: str, name: str, field_path: str) -> str:
    if (
        kind == "ValidatingWebhookConfiguration"
        and name == "kyverno-resource-validating-webhook-cfg"
        and field_path.startswith("webhooks[")
    ):
        return "expected_runtime_churn"
    if kind in EXPECTED_KINDS:
        if namespace == "forgesec" or name.startswith("forgesec-"):
            return "expected_forgesec_transient"
        return "expected_runtime_churn"
    if kind == "Service" and field_path in EXPECTED_SERVICE_FIELD_PATHS:
        return "expected_runtime_churn"
    if kind not in AUTHORITATIVE_KINDS:
        return "expected_runtime_churn"
    return "authoritative"


def load_snapshot(path: Path) -> list[dict[str, Any]]:
    doc = json.loads(path.read_text())
    if isinstance(doc, dict):
        resources = doc.get("resources") or []
    else:
        resources = doc
    if not isinstance(resources, list):
        raise ValueError(f"snapshot at {path} does not contain a resource list")
    return [resource for resource in resources if isinstance(resource, dict)]


def compare_cluster_snapshots(before_path: Path, after_path: Path) -> dict[str, Any]:
    before_resources = {_resource_key(resource): resource for resource in load_snapshot(before_path)}
    after_resources = {_resource_key(resource): resource for resource in load_snapshot(after_path)}

    drift: list[dict[str, Any]] = []
    all_keys = sorted(set(before_resources) | set(after_resources))

    for key in all_keys:
        kind, namespace, name = key
        before_resource = before_resources.get(key)
        after_resource = after_resources.get(key)

        if before_resource is None or after_resource is None:
            field_path = "$resource"
            classification = _classify_drift(kind, namespace, name, field_path)
            drift.append(
                {
                    "resource_kind": kind,
                    "namespace": namespace,
                    "object_name": name,
                    "field_path": field_path,
                    "before_value": before_resource,
                    "after_value": after_resource,
                    "classification": classification,
                }
            )
            continue

        before_flat = _flatten(before_resource)
        after_flat = _flatten(after_resource)
        for field_path in sorted(set(before_flat) | set(after_flat)):
            before_value = before_flat.get(field_path)
            after_value = after_flat.get(field_path)
            if before_value == after_value:
                continue
            drift.append(
                {
                    "resource_kind": kind,
                    "namespace": namespace,
                    "object_name": name,
                    "field_path": field_path,
                    "before_value": before_value,
                    "after_value": after_value,
                    "classification": _classify_drift(kind, namespace, name, field_path),
                }
            )

    summary: dict[str, int] = {}
    for entry in drift:
        classification = str(entry["classification"])
        summary[classification] = summary.get(classification, 0) + 1

    authoritative_drift = [entry for entry in drift if entry["classification"] == "authoritative"]
    return {
        "status": "FAIL" if authoritative_drift else "PASS",
        "fail_class": "NON_DETERMINISM" if authoritative_drift else "NONE",
        "authoritative_drift_detected": bool(authoritative_drift),
        "expected_drift_detected": any(entry["classification"] != "authoritative" for entry in drift),
        "summary": summary,
        "drift": drift,
    }


# Fields excluded from determinism comparison.
# Signatures are verified but excluded from determinism checks
# because ECDSA signatures are non-deterministic: the same payload
# signed twice produces different bytes due to random nonce selection.
# Signature validity and key correctness are enforced by verify_signatures.sh
# which runs as part of every proof run before comparison.
#
# rekorBundle is the Sigstore/Rekor transparency log receipt.  It embeds
# the ECDSA signature (non-deterministic), log index, integrated timestamp,
# and SignedEntryTimestamp — every subfield is ephemeral.  The artifact hash
# that rekorBundle signs is stored separately in the outer JSON and is
# already subject to determinism comparison.
#
# cert_before records the live SVID (serial, valid_from, expiration_time)
# observed at the start of the existing-session-fail-closed test.  SVIDs
# rotate on a ~90s TTL so these values change every run.  The invariant
# being proved (existing_session=fail_closed, fresh_request.successful=False)
# is captured in deterministic fields and is still compared.
#
# wait_seconds is the measured elapsed time until SVID expiry; it varies
# by a few seconds between runs depending on when in the rotation cycle
# the test starts.
#
# pod_before / replacement_pod record the specific Kubernetes pod instance
# names (e.g. test-client-69868c86fd-6vppm) that were live during the test.
# The random 5-char pod suffix changes whenever a pod restarts.  The proof
# invariant (fail-closed behavior, cert_issuance=blocked) is captured in
# deterministic outcome fields and is still compared.
#
# evidence (in status_staging.json) contains raw SHA256 hashes of each proof
# artifact file.  Some artifact files (existing_session_fail_closed.json,
# failure_behavior.json) embed non-deterministic data (cert timestamps, pod
# names), so their file-level hashes change between runs.  The actual content
# of those files is compared directly by first_json_drift() — evidence
# is redundant for determinism purposes.
#
# pod (in workload_spire_issuer_validation.json and related artifacts) is the
# Kubernetes pod instance name including a random suffix (e.g.
# istio-ingressgateway-6d95c64cf-w94hx).  The deterministic identity proof is
# carried by spiffe_id, namespace, issuer, and status, which are still compared.
_NON_DETERMINISTIC_FIELDS = frozenset({
    "base64Signature",
    "signature",
    "rekorBundle",
    "cert_before",
    "wait_seconds",
    "pod_before",
    "replacement_pod",
    "evidence",
    "pod",
})


def _normalize_kyverno_validating_webhook(webhook: Any) -> Any:
    if not isinstance(webhook, dict):
        return _normalize_for_determinism(webhook)

    normalized = {
        key: _normalize_for_determinism(value)
        for key, value in webhook.items()
        if key not in _NON_DETERMINISTIC_FIELDS and key != "rules"
    }

    rules = webhook.get("rules")
    if not isinstance(rules, list):
        if "rules" in webhook:
            normalized["rules"] = _normalize_for_determinism(rules)
        return normalized

    merged_rules: dict[tuple[tuple[str, ...], tuple[str, ...], str], dict[str, Any]] = {}
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        api_groups = tuple(sorted(str(item) for item in (rule.get("apiGroups") or [])))
        api_versions = tuple(sorted(str(item) for item in (rule.get("apiVersions") or [])))
        scope = str(rule.get("scope", "*"))
        key = (api_groups, api_versions, scope)
        bucket = merged_rules.setdefault(
            key,
            {
                "apiGroups": set(api_groups),
                "apiVersions": set(api_versions),
                "operations": set(),
                "resources": set(),
                "scope": scope,
            },
        )
        bucket["operations"].update(str(item) for item in (rule.get("operations") or []))
        bucket["resources"].update(str(item) for item in (rule.get("resources") or []))

    normalized["rules"] = [
        {
            "apiGroups": sorted(bucket["apiGroups"]),
            "apiVersions": sorted(bucket["apiVersions"]),
            "operations": sorted(bucket["operations"]),
            "resources": sorted(bucket["resources"]),
            "scope": bucket["scope"],
        }
        for _, bucket in sorted(merged_rules.items())
    ]
    return normalized


def _normalize_for_determinism(obj: Any) -> Any:
    """Recursively remove non-deterministic fields from a parsed JSON object
    before comparison.  Only top-level keys are targeted; nested keys with
    the same names are also stripped to handle wrapped bundle structures.
    """
    if isinstance(obj, dict):
        if (
            obj.get("kind") == "ValidatingWebhookConfiguration"
            and isinstance(obj.get("metadata"), dict)
            and obj["metadata"].get("name") == "kyverno-resource-validating-webhook-cfg"
            and isinstance(obj.get("webhooks"), list)
        ):
            normalized = {
                k: _normalize_for_determinism(v)
                for k, v in obj.items()
                if k not in _NON_DETERMINISTIC_FIELDS and k != "webhooks"
            }
            normalized["webhooks"] = [
                _normalize_kyverno_validating_webhook(webhook)
                for webhook in obj.get("webhooks", [])
            ]
            return normalized
        return {
            k: _normalize_for_determinism(v)
            for k, v in obj.items()
            if k not in _NON_DETERMINISTIC_FIELDS
        }
    if isinstance(obj, list):
        return [_normalize_for_determinism(item) for item in obj]
    return obj


def first_json_drift(run1_dir: Path, run2_dir: Path) -> int:
    """Determinism first-drift extraction with explicit boundary classification.

    Fatal classes:
      - canonical_semantic_drift
      - canonical_inventory_drift

    Non-fatal classes:
      - operational_artifact_drift
      - non_deterministic_by_design
      - unstable_collection_boundary
    """
    drift_class, _details = compare_with_canonical_inventory(run1_dir, run2_dir, emit_first_drift=True)
    if drift_class in {"canonical_semantic_drift", "canonical_inventory_drift"}:
        return 2
    return 0


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ThreadForge proof hardening helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_hash = sub.add_parser("hash", help="Hash all files in artifact directory")
    p_hash.add_argument("artifact_dir")

    p_compare = sub.add_parser("compare", help="Compare artifact directory hashes")
    p_compare.add_argument("run1_dir")
    p_compare.add_argument("run2_dir")

    p_compare_cluster = sub.add_parser("compare-cluster", help="Compare classified cluster snapshots")
    p_compare_cluster.add_argument("before_snapshot")
    p_compare_cluster.add_argument("after_snapshot")
    p_compare_cluster.add_argument("report_path")

    p_first_drift = sub.add_parser(
        "compare-artifacts",
        help="Find and print the first JSON field that diverges between two proof artifact directories",
    )
    p_first_drift.add_argument("run1_dir")
    p_first_drift.add_argument("run2_dir")

    args = parser.parse_args(argv)

    if args.cmd == "hash":
        print(hash_artifacts(Path(args.artifact_dir)))
        return 0

    if args.cmd == "compare":
        drift_class, details = compare_with_canonical_inventory(
            Path(args.run1_dir),
            Path(args.run2_dir),
            emit_first_drift=False,
        )
        if drift_class in {"canonical_semantic_drift", "canonical_inventory_drift"}:
            exit_with_failure(FailureClass.NON_DETERMINISM, f"{drift_class}: {details}")
        if drift_class == "none":
            print("[PASS] determinism: canonical artifact inventory and semantic projections match")
            return 0
        print(f"[PASS] determinism: {drift_class} classified (non-semantic)")
        return 0

    if args.cmd == "compare-cluster":
        report = compare_cluster_snapshots(Path(args.before_snapshot), Path(args.after_snapshot))
        report_path = Path(args.report_path)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        if report["status"] != "PASS":
            exit_with_failure(FailureClass.NON_DETERMINISM, "authoritative cluster drift detected")
        print(
            "[PASS] determinism: cluster drift classified "
            f"(authoritative={report['summary'].get('authoritative', 0)} "
            f"expected={sum(count for key, count in report['summary'].items() if key != 'authoritative')})"
        )
        return 0

    if args.cmd == "compare-artifacts":
        return first_json_drift(Path(args.run1_dir), Path(args.run2_dir))

    return 99


if __name__ == "__main__":
    raise SystemExit(_main())
