#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CANONICAL_PATH = REPO_ROOT / "platform" / "deploy" / "infra" / "grafana" / "templates" / "statefulset.yaml"
DEFAULT_RENDERED_PATHS = (
    REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "grafana.yaml",
    REPO_ROOT / "platform" / "deploy" / "gitops" / "infra" / "observability" / "grafana.yaml",
)
DEFAULT_NAMESPACE = "observability"
DEFAULT_WORKLOAD_KIND = "Deployment"
DEFAULT_WORKLOAD_NAME = "grafana"
DEFAULT_TARGET_NAME = "grafana"
DEFAULT_ARTIFACT_PATH = REPO_ROOT / "artifacts" / "proof" / "latest" / "workload_projection_continuity.json"
DEFAULT_HELM_RELEASE = "grafana"

RELEVANT_LABEL_KEYS = (
    "app",
    "app.kubernetes.io/name",
)
RELEVANT_ANNOTATION_KEYS = (
    "proxy.istio.io/config",
    "sidecar.istio.io/inject",
    "sidecar.istio.io/userVolume",
    "sidecar.istio.io/userVolumeMount",
)
IGNORED_CONTAINER_NAMES = {"istio-proxy"}


@dataclass(frozen=True)
class WorkloadTarget:
    name: str
    namespace: str
    canonical_path: Path
    canonical_kind: str
    rendered_paths: tuple[Path, ...]
    rendered_kind: str
    applied_kind: str
    applied_name: str


DEFAULT_TARGETS = (
    WorkloadTarget(
        name=DEFAULT_TARGET_NAME,
        namespace=DEFAULT_NAMESPACE,
        canonical_path=DEFAULT_CANONICAL_PATH,
        canonical_kind="StatefulSet",
        rendered_paths=DEFAULT_RENDERED_PATHS,
        rendered_kind="Deployment",
        applied_kind=DEFAULT_WORKLOAD_KIND,
        applied_name=DEFAULT_WORKLOAD_NAME,
    ),
)


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def _render_helm_documents(chart_dir: Path, release_name: str, namespace: str) -> list[dict[str, Any]]:
    proc = _run(["helm", "template", release_name, str(chart_dir), "-n", namespace])
    if proc.returncode != 0 or not proc.stdout.strip():
        stderr = proc.stderr.strip() or proc.stdout.strip() or "helm template failed"
        raise FileNotFoundError(f"unable to render {chart_dir} via helm: {stderr}")
    docs = [doc for doc in yaml.safe_load_all(proc.stdout) if isinstance(doc, dict)]
    return docs


def _load_yaml_documents(path: Path) -> list[dict[str, Any]]:
    if path == DEFAULT_CANONICAL_PATH:
        return _render_helm_documents(path.parents[1], DEFAULT_HELM_RELEASE, DEFAULT_NAMESPACE)
    raw = path.read_text(encoding="utf-8")
    return [doc for doc in yaml.safe_load_all(raw) if isinstance(doc, dict)]


def _select_document(docs: Iterable[dict[str, Any]], kind: str, name: str, namespace: str) -> dict[str, Any]:
    for doc in docs:
        metadata = doc.get("metadata") or {}
        if (
            str(doc.get("kind") or "") == kind
            and str(metadata.get("name") or "") == name
            and str(metadata.get("namespace") or "") == namespace
        ):
            return doc
    raise FileNotFoundError(f"unable to find {kind} {namespace}/{name}")


def _select_mapping(source: dict[str, Any] | None, keys: Iterable[str]) -> dict[str, Any]:
    if not isinstance(source, dict):
        return {}
    projected: dict[str, Any] = {}
    for key in keys:
        if key in source:
            projected[key] = source[key]
    return {key: projected[key] for key in sorted(projected)}


def _normalize_volume(volume: dict[str, Any]) -> dict[str, Any]:
    projected: dict[str, Any] = {"name": volume.get("name")}
    for key in (
        "configMap",
        "emptyDir",
        "projected",
        "secret",
        "persistentVolumeClaim",
        "downwardAPI",
        "hostPath",
    ):
        value = volume.get(key)
        if value is None:
            continue
        if isinstance(value, dict):
            normalized = json.loads(json.dumps(value, sort_keys=True))
            if isinstance(normalized, dict):
                normalized.pop("defaultMode", None)
            projected[key] = normalized
        else:
            projected[key] = value
    return projected


def _normalize_volume_mount(mount: dict[str, Any]) -> dict[str, Any]:
    projected: dict[str, Any] = {"name": mount.get("name"), "mountPath": mount.get("mountPath")}
    for key in ("readOnly", "subPath", "subPathExpr", "mountPropagation"):
        if key in mount:
            projected[key] = mount[key]
    return projected


def _normalize_container(container: dict[str, Any], expected_mount_names: set[str] | None = None) -> dict[str, Any]:
    projected: dict[str, Any] = {"name": container.get("name")}
    mounts = container.get("volumeMounts") or []
    if isinstance(mounts, list):
        normalized_mounts = []
        for mount in mounts:
            if not isinstance(mount, dict):
                continue
            if expected_mount_names is not None and mount.get("name") not in expected_mount_names:
                continue
            normalized_mounts.append(_normalize_volume_mount(mount))
        projected["volumeMounts"] = sorted(
            normalized_mounts,
            key=lambda item: (str(item.get("name") or ""), str(item.get("mountPath") or "")),
        )
    return projected


def _extract_pod_spec(doc: dict[str, Any]) -> dict[str, Any]:
    spec = doc.get("spec") or {}
    if not isinstance(spec, dict):
        return {}
    template = spec.get("template")
    if isinstance(template, dict):
        template_spec = template.get("spec")
        if isinstance(template_spec, dict):
            return template_spec
    return spec


def _extract_pod_metadata(doc: dict[str, Any]) -> dict[str, Any]:
    spec = doc.get("spec") or {}
    if isinstance(spec, dict):
        template = spec.get("template")
        if isinstance(template, dict):
            metadata = template.get("metadata")
            if isinstance(metadata, dict):
                return metadata
    metadata = doc.get("metadata")
    return metadata if isinstance(metadata, dict) else {}


def project_workload(doc: dict[str, Any], selectors: dict[str, set[str]] | None = None) -> dict[str, Any]:
    metadata = doc.get("metadata") or {}
    pod_metadata = _extract_pod_metadata(doc)
    pod_spec = _extract_pod_spec(doc)
    labels = pod_metadata.get("labels") or {}
    annotations = pod_metadata.get("annotations") or {}
    containers = pod_spec.get("containers") or []
    container_names = selectors.get("container_names") if selectors else None
    volume_names = selectors.get("volume_names") if selectors else None

    if not isinstance(labels, dict):
        labels = {}
    if not isinstance(annotations, dict):
        annotations = {}

    projected_containers = []
    if isinstance(containers, list):
        for container in containers:
            if not isinstance(container, dict):
                continue
            name = str(container.get("name") or "")
            if name in IGNORED_CONTAINER_NAMES:
                continue
            if container_names is not None and name not in container_names:
                continue
            mounts = container.get("volumeMounts") or []
            if volume_names is not None and isinstance(mounts, list):
                mounts = [mount for mount in mounts if isinstance(mount, dict) and mount.get("name") in volume_names]
            projected_containers.append(
                _normalize_container(
                    {
                        "name": name,
                        "volumeMounts": mounts,
                    },
                    expected_mount_names=volume_names,
                )
            )

    projected_volumes = []
    volumes = pod_spec.get("volumes") or []
    if isinstance(volumes, list):
        for volume in volumes:
            if not isinstance(volume, dict):
                continue
            name = str(volume.get("name") or "")
            if volume_names is not None and name not in volume_names:
                continue
            projected_volumes.append(_normalize_volume(volume))

    return {
        "metadata": {
            "namespace": metadata.get("namespace"),
            "labels": _select_mapping(labels, selectors.get("label_keys") if selectors else labels.keys()),
            "annotations": _select_mapping(
                annotations,
                selectors.get("annotation_keys") if selectors else annotations.keys(),
            ),
        },
        "spec": {
            "serviceAccountName": pod_spec.get("serviceAccountName"),
            "automountServiceAccountToken": pod_spec.get("automountServiceAccountToken"),
            "priorityClassName": pod_spec.get("priorityClassName"),
            "volumes": sorted(projected_volumes, key=lambda item: str(item.get("name") or "")),
            "containers": sorted(
                projected_containers,
                key=lambda item: str(item.get("name") or ""),
            ),
        },
    }


def projection_selectors(projection: dict[str, Any]) -> dict[str, set[str]]:
    metadata = projection.get("metadata") or {}
    spec = projection.get("spec") or {}
    annotations = metadata.get("annotations") or {}
    volume_names: set[str] = set()
    user_volume_annotation = annotations.get("sidecar.istio.io/userVolume")
    if isinstance(user_volume_annotation, str) and user_volume_annotation.strip():
        try:
            parsed = json.loads(user_volume_annotation)
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            volume_names = {str(key) for key in parsed.keys() if str(key).strip()}
    if not volume_names:
        volume_names = {
            str(item.get("name") or "")
            for item in (spec.get("volumes") or [])
            if isinstance(item, dict) and str(item.get("name") or "").strip()
        }
    return {
        "label_keys": {key for key in (metadata.get("labels") or {}).keys() if key in RELEVANT_LABEL_KEYS},
        "annotation_keys": {key for key in annotations.keys() if key in RELEVANT_ANNOTATION_KEYS},
        "volume_names": volume_names,
        "container_names": {
            str(item.get("name") or "") for item in (spec.get("containers") or []) if isinstance(item, dict)
        },
    }


def _first_value_drift(left: Any, right: Any, prefix: str = "") -> tuple[str, Any, Any] | None:
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            next_prefix = f"{prefix}.{key}" if prefix else key
            if key not in left:
                return next_prefix, None, right[key]
            if key not in right:
                return next_prefix, left[key], None
            drift = _first_value_drift(left[key], right[key], next_prefix)
            if drift is not None:
                return drift
        return None
    if isinstance(left, list) and isinstance(right, list):
        for index in range(max(len(left), len(right))):
            next_prefix = f"{prefix}[{index}]" if prefix else f"[{index}]"
            if index >= len(left):
                return next_prefix, None, right[index]
            if index >= len(right):
                return next_prefix, left[index], None
            drift = _first_value_drift(left[index], right[index], next_prefix)
            if drift is not None:
                return drift
        return None
    if left != right:
        return prefix or "$", left, right
    return None


def _owner_uid(obj: dict[str, Any], kind: str) -> str | None:
    metadata = obj.get("metadata") or {}
    if not isinstance(metadata, dict):
        return None
    for ref in metadata.get("ownerReferences") or []:
        if not isinstance(ref, dict):
            continue
        if str(ref.get("kind") or "") == kind:
            uid = ref.get("uid")
            if isinstance(uid, str) and uid.strip():
                return uid
    return None


def _pick_owner(objects: list[dict[str, Any]], owner_uid: str, owner_kind: str) -> dict[str, Any]:
    matches = [obj for obj in objects if _owner_uid(obj, owner_kind) == owner_uid]
    if not matches:
        raise FileNotFoundError(f"no owned {owner_kind} found for uid={owner_uid}")
    matches.sort(
        key=lambda item: (
            str((item.get("metadata") or {}).get("creationTimestamp") or ""),
            str((item.get("metadata") or {}).get("name") or ""),
        )
    )
    return matches[-1]


def _deployment_active_replica_set_name(deployment: dict[str, Any]) -> str | None:
    status = deployment.get("status") or {}
    if not isinstance(status, dict):
        return None
    for condition in status.get("conditions") or []:
        if not isinstance(condition, dict):
            continue
        if condition.get("type") != "Progressing":
            continue
        if condition.get("status") != "True":
            continue
        reason = str(condition.get("reason") or "")
        message = str(condition.get("message") or "")
        if reason == "NewReplicaSetAvailable":
            import re

            match = re.search(r'ReplicaSet "([^"]+)"', message)
            if match:
                return match.group(1)
        if reason.startswith("ReplicaSet"):
            parts = reason.split()
            if len(parts) >= 2 and parts[1]:
                return parts[1]
    return None


def _pick_active_replica_set(
    objects: list[dict[str, Any]], deployment: dict[str, Any], owner_uid: str
) -> dict[str, Any]:
    preferred_name = _deployment_active_replica_set_name(deployment)
    candidates = [obj for obj in objects if _owner_uid(obj, "Deployment") == owner_uid]
    if not candidates:
        raise FileNotFoundError(f"no owned ReplicaSet found for uid={owner_uid}")
    if preferred_name:
        for obj in candidates:
            metadata = obj.get("metadata") or {}
            if str(metadata.get("name") or "") == preferred_name:
                return obj
    ready_candidates = []
    for obj in candidates:
        status = obj.get("status") or {}
        if not isinstance(status, dict):
            continue
        if any(
            isinstance(condition, dict) and condition.get("type") == "Progressing" and condition.get("status") == "True"
            for condition in (deployment.get("status") or {}).get("conditions") or []
        ):
            ready_candidates.append(obj)
            continue
        if (
            (status.get("replicas") or 0)
            or (status.get("readyReplicas") or 0)
            or (status.get("availableReplicas") or 0)
        ):
            ready_candidates.append(obj)
    if ready_candidates:
        ready_candidates.sort(
            key=lambda item: (
                int(((item.get("status") or {}).get("availableReplicas") or 0)),
                int(((item.get("status") or {}).get("readyReplicas") or 0)),
                int(((item.get("status") or {}).get("replicas") or 0)),
                str((item.get("metadata") or {}).get("creationTimestamp") or ""),
                str((item.get("metadata") or {}).get("name") or ""),
            )
        )
        return ready_candidates[-1]
    candidates.sort(
        key=lambda item: (
            str((item.get("metadata") or {}).get("creationTimestamp") or ""),
            str((item.get("metadata") or {}).get("name") or ""),
        )
    )
    return candidates[-1]


def _pick_running_pod(pods: list[dict[str, Any]], owner_uid: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    for pod in pods:
        metadata = pod.get("metadata") or {}
        if not isinstance(metadata, dict):
            continue
        if metadata.get("deletionTimestamp"):
            continue
        if _owner_uid(pod, "ReplicaSet") != owner_uid:
            continue
        status = pod.get("status") or {}
        if not isinstance(status, dict):
            continue
        if status.get("phase") != "Running":
            continue
        if not any(
            isinstance(condition, dict) and condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in status.get("conditions") or []
        ):
            continue
        matches.append(pod)

    if not matches:
        raise FileNotFoundError(f"no running pod owned by ReplicaSet uid={owner_uid}")
    if len(matches) > 1:
        raise ValueError(f"multiple running pods owned by ReplicaSet uid={owner_uid}")
    return matches[0]


def compare_projection_chain(
    *,
    target: WorkloadTarget,
    canonical_doc: dict[str, Any],
    rendered_docs: list[tuple[Path, dict[str, Any]]],
    applied_doc: dict[str, Any],
    running_doc: dict[str, Any],
) -> dict[str, Any]:
    canonical_seed = project_workload(canonical_doc)
    selectors = projection_selectors(canonical_seed)
    canonical_projection = project_workload(canonical_doc, selectors)
    canonical_identity = {
        "path": str(target.canonical_path),
        "kind": target.canonical_kind,
        "name": target.name,
        "namespace": target.namespace,
    }
    rendered_identity = []

    for rendered_path, rendered_doc in rendered_docs:
        rendered_projection = project_workload(rendered_doc, selectors)
        drift = _first_value_drift(canonical_projection, rendered_projection)
        rendered_identity.append(
            {
                "path": str(rendered_path),
                "kind": str(rendered_doc.get("kind") or ""),
                "projection": rendered_projection,
            }
        )
        if drift is not None:
            field, expected, observed = drift
            return {
                "status": "FAIL",
                "fail_class": "WORKLOAD_PROJECTION_DRIFT",
                "producer": str(rendered_path),
                "consumer": str(target.canonical_path),
                "first_divergence": {
                    "stage": "rendered_manifest",
                    "field": field,
                    "expected": expected,
                    "observed": observed,
                },
                "identity_chain": {
                    "canonical": canonical_identity,
                    "rendered": rendered_identity,
                },
                "projections": {
                    "canonical": canonical_projection,
                    "rendered": rendered_projection,
                },
            }

    applied_projection = project_workload(applied_doc, selectors)
    drift = _first_value_drift(canonical_projection, applied_projection)
    if drift is not None:
        field, expected, observed = drift
        return {
            "status": "FAIL",
            "fail_class": "WORKLOAD_PROJECTION_DRIFT",
            "producer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "consumer": str(rendered_docs[-1][0]) if rendered_docs else str(target.canonical_path),
            "first_divergence": {
                "stage": "applied_deployment",
                "field": field,
                "expected": expected,
                "observed": observed,
            },
            "identity_chain": {
                "canonical": canonical_identity,
                "rendered": rendered_identity,
                "applied": {
                    "kind": str(applied_doc.get("kind") or ""),
                    "name": (applied_doc.get("metadata") or {}).get("name"),
                    "namespace": (applied_doc.get("metadata") or {}).get("namespace"),
                    "uid": (applied_doc.get("metadata") or {}).get("uid"),
                    "resourceVersion": (applied_doc.get("metadata") or {}).get("resourceVersion"),
                    "creationTimestamp": (applied_doc.get("metadata") or {}).get("creationTimestamp"),
                    "ownerReferences": json.loads(
                        json.dumps((applied_doc.get("metadata") or {}).get("ownerReferences") or [])
                    ),
                },
            },
            "projections": {
                "canonical": canonical_projection,
                "applied": applied_projection,
            },
        }

    deployment_uid = (applied_doc.get("metadata") or {}).get("uid")
    if not isinstance(deployment_uid, str) or not deployment_uid.strip():
        return {
            "status": "FAIL",
            "fail_class": "MISSING_PREREQ",
            "producer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "consumer": str(target.canonical_path),
            "first_divergence": {
                "stage": "applied_deployment",
                "field": "metadata.uid",
                "expected": "<present>",
                "observed": "<absent>",
            },
        }

    # The running workload must be identity-bound to the applied deployment via
    # the owned ReplicaSet and owned Pod.  Discovery is by ownerReferences, not
    # by label ordering.
    live_selector = selectors
    pod_projection = project_workload(running_doc, live_selector)
    drift = _first_value_drift(canonical_projection, pod_projection)
    if drift is not None:
        field, expected, observed = drift
        return {
            "status": "FAIL",
            "fail_class": "WORKLOAD_PROJECTION_DRIFT",
            "producer": f"pod/{(running_doc.get('metadata') or {}).get('name')}",
            "consumer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "first_divergence": {
                "stage": "running_workload",
                "field": field,
                "expected": expected,
                "observed": observed,
            },
            "identity_chain": {
                "canonical": canonical_identity,
                "rendered": rendered_identity,
                "applied": {
                    "kind": str(applied_doc.get("kind") or ""),
                    "name": (applied_doc.get("metadata") or {}).get("name"),
                    "namespace": (applied_doc.get("metadata") or {}).get("namespace"),
                    "uid": deployment_uid,
                    "resourceVersion": (applied_doc.get("metadata") or {}).get("resourceVersion"),
                    "creationTimestamp": (applied_doc.get("metadata") or {}).get("creationTimestamp"),
                    "ownerReferences": json.loads(
                        json.dumps((applied_doc.get("metadata") or {}).get("ownerReferences") or [])
                    ),
                },
                "running": {
                    "kind": str(running_doc.get("kind") or ""),
                    "name": (running_doc.get("metadata") or {}).get("name"),
                    "namespace": (running_doc.get("metadata") or {}).get("namespace"),
                    "uid": (running_doc.get("metadata") or {}).get("uid"),
                    "resourceVersion": (running_doc.get("metadata") or {}).get("resourceVersion"),
                    "creationTimestamp": (running_doc.get("metadata") or {}).get("creationTimestamp"),
                    "ownerReferences": json.loads(
                        json.dumps((running_doc.get("metadata") or {}).get("ownerReferences") or [])
                    ),
                },
            },
            "projections": {
                "canonical": canonical_projection,
                "running": pod_projection,
            },
        }

    return {
        "status": "PASS",
        "fail_class": None,
        "producer": f"{target.applied_kind.lower()}/{target.applied_name}",
        "consumer": str(target.canonical_path),
        "first_divergence": None,
        "identity_chain": {
            "canonical": canonical_identity,
            "rendered": rendered_identity,
            "applied": {
                "kind": str(applied_doc.get("kind") or ""),
                "name": (applied_doc.get("metadata") or {}).get("name"),
                "namespace": (applied_doc.get("metadata") or {}).get("namespace"),
                "uid": deployment_uid,
                "resourceVersion": (applied_doc.get("metadata") or {}).get("resourceVersion"),
                "creationTimestamp": (applied_doc.get("metadata") or {}).get("creationTimestamp"),
                "ownerReferences": json.loads(
                    json.dumps((applied_doc.get("metadata") or {}).get("ownerReferences") or [])
                ),
            },
            "running": {
                "kind": str(running_doc.get("kind") or ""),
                "name": (running_doc.get("metadata") or {}).get("name"),
                "namespace": (running_doc.get("metadata") or {}).get("namespace"),
                "uid": (running_doc.get("metadata") or {}).get("uid"),
                "resourceVersion": (running_doc.get("metadata") or {}).get("resourceVersion"),
                "creationTimestamp": (running_doc.get("metadata") or {}).get("creationTimestamp"),
                "ownerReferences": json.loads(
                    json.dumps((running_doc.get("metadata") or {}).get("ownerReferences") or [])
                ),
            },
        },
        "projections": {
            "canonical": canonical_projection,
            "rendered": rendered_identity[-1]["projection"] if rendered_identity else {},
            "applied": applied_projection,
            "running": pod_projection,
        },
    }


def _load_live_object(namespace: str, kind: str, name: str) -> dict[str, Any]:
    proc = _run(["kubectl", "-n", namespace, "get", kind.lower(), name, "-o", "json"])
    if proc.returncode != 0 or not proc.stdout.strip():
        raise FileNotFoundError(f"unable to load live {kind} {namespace}/{name}")
    return json.loads(proc.stdout)


def _load_live_objects(namespace: str, kind: str) -> list[dict[str, Any]]:
    proc = _run(["kubectl", "-n", namespace, "get", kind, "-o", "json"])
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    doc = json.loads(proc.stdout)
    items = doc.get("items") or []
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict)]


def run_target(target: WorkloadTarget) -> dict[str, Any]:
    canonical_docs = _load_yaml_documents(target.canonical_path)
    canonical_doc = _select_document(canonical_docs, target.canonical_kind, target.name, target.namespace)

    rendered_docs: list[tuple[Path, dict[str, Any]]] = []
    for rendered_path in target.rendered_paths:
        rendered_doc = _select_document(
            _load_yaml_documents(rendered_path),
            target.rendered_kind,
            target.name,
            target.namespace,
        )
        rendered_docs.append((rendered_path, rendered_doc))

    applied_doc = _load_live_object(target.namespace, target.applied_kind, target.applied_name)
    deployment_uid = (applied_doc.get("metadata") or {}).get("uid")
    if not isinstance(deployment_uid, str) or not deployment_uid.strip():
        return {
            "status": "FAIL",
            "fail_class": "MISSING_PREREQ",
            "producer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "consumer": str(target.canonical_path),
            "first_divergence": {
                "stage": "applied_deployment",
                "field": "metadata.uid",
                "expected": "<present>",
                "observed": "<absent>",
            },
        }

    replica_sets = _load_live_objects(target.namespace, "replicasets")
    active_rs = _pick_active_replica_set(replica_sets, applied_doc, deployment_uid)
    active_rs_uid = (active_rs.get("metadata") or {}).get("uid")
    if not isinstance(active_rs_uid, str) or not active_rs_uid.strip():
        return {
            "status": "FAIL",
            "fail_class": "MISSING_PREREQ",
            "producer": f"replicaset/{(active_rs.get('metadata') or {}).get('name')}",
            "consumer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "first_divergence": {
                "stage": "applied_deployment",
                "field": "metadata.uid",
                "expected": "<present>",
                "observed": "<absent>",
            },
        }

    pods = _load_live_objects(target.namespace, "pods")
    running_pod = _pick_running_pod(pods, active_rs_uid)
    return compare_projection_chain(
        target=target,
        canonical_doc=canonical_doc,
        rendered_docs=rendered_docs,
        applied_doc=applied_doc,
        running_doc=running_pod,
    )


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify workload projection continuity")
    parser.add_argument("--artifact", default=str(DEFAULT_ARTIFACT_PATH))
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument("--workload", default=DEFAULT_WORKLOAD_NAME)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    target = DEFAULT_TARGETS[0]
    if args.namespace != target.namespace or args.workload != target.name:
        raise SystemExit("[FAIL] CONTRACT_VIOLATION: unknown workload target")

    try:
        report = run_target(target)
    except FileNotFoundError as exc:
        report = {
            "status": "FAIL",
            "fail_class": "MISSING_PREREQ",
            "producer": str(target.canonical_path),
            "consumer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "first_divergence": {
                "stage": "applied_deployment",
                "field": "$missing_resource",
                "expected": "<present>",
                "observed": str(exc),
            },
        }
        if not args.dry_run:
            write_report(Path(args.artifact), report)
        print(f"[FAIL] MISSING_PREREQ: {exc}")
        return 20
    except ValueError as exc:
        report = {
            "status": "FAIL",
            "fail_class": "WORKLOAD_PROJECTION_DRIFT",
            "producer": f"{target.applied_kind.lower()}/{target.applied_name}",
            "consumer": str(target.canonical_path),
            "first_divergence": {
                "stage": "running_workload",
                "field": "$identity_ambiguity",
                "expected": "exactly one owned running pod",
                "observed": str(exc),
            },
        }
        if not args.dry_run:
            write_report(Path(args.artifact), report)
        print(f"[FAIL] WORKLOAD_PROJECTION_DRIFT: {exc}")
        return 2

    if not args.dry_run:
        write_report(Path(args.artifact), report)

    if report.get("status") == "PASS":
        print("[PASS] workload projection continuity verified")
        return 0

    first = report.get("first_divergence") or {}
    stage = first.get("stage", "unknown")
    field = first.get("field", "unknown")
    expected = first.get("expected", "<unknown>")
    observed = first.get("observed", "<unknown>")
    print(
        f"[FAIL] WORKLOAD_PROJECTION_DRIFT: stage={stage} field={field} " f"expected={expected!r} observed={observed!r}"
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
