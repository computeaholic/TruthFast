from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest


pytestmark = [pytest.mark.unit]

REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "verify" / "workload_projection_continuity.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("workload_projection_continuity_test_module", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _workload_doc(kind: str, name: str, namespace: str, service_account: str = "grafana-sa") -> dict:
    return {
        "apiVersion": "apps/v1",
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {"app": "grafana", "app.kubernetes.io/name": "grafana", "noise": "ignored"},
            "annotations": {
                "sidecar.istio.io/inject": "true",
                "sidecar.istio.io/userVolume": '{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}',
                "sidecar.istio.io/userVolumeMount": '{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}',
                "noise": "ignored",
            },
        },
        "spec": {
            "template": {
                "metadata": {
                    "labels": {"app": "grafana", "app.kubernetes.io/name": "grafana"},
                    "annotations": {
                        "sidecar.istio.io/inject": "true",
                        "sidecar.istio.io/userVolume": '{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}',
                        "sidecar.istio.io/userVolumeMount": '{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}',
                    },
                },
                "spec": {
                    "serviceAccountName": service_account,
                    "automountServiceAccountToken": False,
                    "priorityClassName": "threadforge-observability",
                    "volumes": [
                        {"name": "storage", "emptyDir": {}},
                        {
                            "name": "istio-custom-root-cert",
                            "configMap": {"name": "istio-ca-root-cert"},
                        },
                    ],
                    "containers": [
                        {
                            "name": "grafana",
                            "image": "registry.threadforge.local:30500/grafana@sha256:deadbeef",
                            "volumeMounts": [
                                {"name": "storage", "mountPath": "/var/lib/grafana"},
                                {"name": "istio-custom-root-cert", "mountPath": "/etc/certs", "readOnly": True},
                            ],
                        },
                        {
                            "name": "istio-proxy",
                            "image": "registry.threadforge.local:30500/istio-proxy@sha256:deadbeef",
                            "volumeMounts": [{"name": "istio-custom-root-cert", "mountPath": "/etc/certs"}],
                        },
                    ],
                },
            }
        },
    }


def _deployment_doc() -> dict:
    doc = _workload_doc("Deployment", "grafana", "observability")
    doc["metadata"]["uid"] = "deployment-uid"
    doc["metadata"]["resourceVersion"] = "2"
    doc["metadata"]["creationTimestamp"] = "2026-08-01T00:00:01Z"
    return doc


def _statefulset_doc() -> dict:
    doc = _workload_doc("StatefulSet", "grafana", "observability")
    doc["metadata"]["uid"] = "statefulset-uid"
    doc["metadata"]["resourceVersion"] = "1"
    doc["metadata"]["creationTimestamp"] = "2026-08-01T00:00:00Z"
    return doc


def _replicaset(name: str, uid: str, deployment_uid: str, created: str) -> dict:
    return {
        "apiVersion": "apps/v1",
        "kind": "ReplicaSet",
        "metadata": {
            "name": name,
            "namespace": "observability",
            "uid": uid,
            "resourceVersion": "1",
            "creationTimestamp": created,
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": "Deployment",
                    "name": "grafana",
                    "uid": deployment_uid,
                    "controller": True,
                    "blockOwnerDeletion": True,
                }
            ],
        },
    }


def _pod(name: str, uid: str, replica_uid: str, created: str, ready: bool = True, deletion_timestamp: str | None = None) -> dict:
    metadata = {
        "name": name,
        "namespace": "observability",
        "uid": uid,
        "resourceVersion": "1",
        "creationTimestamp": created,
        "ownerReferences": [
            {
                "apiVersion": "apps/v1",
                "kind": "ReplicaSet",
                "name": "grafana",
                "uid": replica_uid,
                "controller": True,
                "blockOwnerDeletion": True,
            }
        ],
        "labels": {"app": "grafana", "app.kubernetes.io/name": "grafana"},
        "annotations": {
            "sidecar.istio.io/inject": "true",
            "sidecar.istio.io/userVolume": '{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}',
            "sidecar.istio.io/userVolumeMount": '{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}',
        },
    }
    if deletion_timestamp is not None:
        metadata["deletionTimestamp"] = deletion_timestamp
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": metadata,
        "status": {
            "phase": "Running",
            "conditions": [
                {"type": "Ready", "status": "True" if ready else "False"},
            ],
        },
        "spec": {
            "serviceAccountName": "grafana-sa",
            "automountServiceAccountToken": False,
            "priorityClassName": "threadforge-observability",
            "volumes": [
                {"name": "storage", "emptyDir": {}},
                {"name": "istio-custom-root-cert", "configMap": {"name": "istio-ca-root-cert"}},
            ],
            "containers": [
                {
                    "name": "grafana",
                    "volumeMounts": [
                        {"name": "storage", "mountPath": "/var/lib/grafana"},
                        {"name": "istio-custom-root-cert", "mountPath": "/etc/certs", "readOnly": True},
                    ],
                },
                {
                    "name": "istio-proxy",
                    "volumeMounts": [{"name": "istio-custom-root-cert", "mountPath": "/etc/certs"}],
                },
            ],
        },
    }


def _wire_module(module, pod_order: list[dict] | None = None) -> tuple[dict, dict, dict, list[dict]]:
    canonical = _statefulset_doc()
    rendered = _deployment_doc()
    deployment = _deployment_doc()
    deployment["metadata"]["uid"] = "deployment-uid"
    active_rs = _replicaset("grafana-77c9d4f7f9", "rs-active", "deployment-uid", "2026-08-01T00:00:02Z")
    stale_rs = _replicaset("grafana-65f4d6f5cc", "rs-stale", "deployment-uid", "2026-07-31T23:59:59Z")
    pods = pod_order if pod_order is not None else [
        _pod("grafana-deleted", "pod-deleted", "rs-stale", "2026-07-31T23:58:00Z", deletion_timestamp="2026-08-01T00:00:00Z"),
        _pod("grafana-stale", "pod-stale", "rs-stale", "2026-07-31T23:59:59Z"),
        _pod("grafana-active", "pod-active", "rs-active", "2026-08-01T00:00:03Z"),
    ]

    module._load_yaml_documents = lambda path: [canonical] if path.name == "statefulset.yaml" else [rendered]
    module._load_live_object = lambda namespace, kind, name: deployment

    def _load_live_objects(namespace: str, kind: str) -> list[dict]:
        if kind == "replicasets":
            return [stale_rs, active_rs]
        if kind == "pods":
            return pods
        return []

    module._load_live_objects = _load_live_objects
    return deployment, active_rs, stale_rs, pods


def test_run_target_binds_to_owned_pod_and_ignores_label_collisions() -> None:
    module = _load_module()
    deployment, _, _, pods = _wire_module(module)

    result = module.run_target(module.DEFAULT_TARGETS[0])

    assert result["status"] == "PASS"
    assert result["identity_chain"]["applied"]["uid"] == deployment["metadata"]["uid"]
    assert result["identity_chain"]["running"]["name"] == "grafana-active"
    assert result["identity_chain"]["running"]["uid"] == "pod-active"
    assert result["projections"]["running"]["spec"]["serviceAccountName"] == "grafana-sa"
    assert any(pod["metadata"]["name"] == "grafana-deleted" for pod in pods)


def test_run_target_is_stable_when_pod_order_changes() -> None:
    module = _load_module()
    _wire_module(module, pod_order=[
        _pod("grafana-active", "pod-active", "rs-active", "2026-08-01T00:00:03Z"),
        _pod("grafana-stale", "pod-stale", "rs-stale", "2026-07-31T23:59:59Z"),
    ])
    first = module.run_target(module.DEFAULT_TARGETS[0])

    module = _load_module()
    _wire_module(module, pod_order=[
        _pod("grafana-stale", "pod-stale", "rs-stale", "2026-07-31T23:59:59Z"),
        _pod("grafana-active", "pod-active", "rs-active", "2026-08-01T00:00:03Z"),
    ])
    second = module.run_target(module.DEFAULT_TARGETS[0])

    assert first["identity_chain"]["running"]["uid"] == second["identity_chain"]["running"]["uid"] == "pod-active"
    assert first["identity_chain"]["running"]["name"] == second["identity_chain"]["running"]["name"] == "grafana-active"


def test_run_target_rejects_owner_reference_mismatch() -> None:
    module = _load_module()
    _wire_module(
        module,
        pod_order=[
            _pod("grafana-wrong", "pod-wrong", "rs-wrong", "2026-08-01T00:00:03Z"),
        ],
    )

    with pytest.raises(FileNotFoundError):
        module.run_target(module.DEFAULT_TARGETS[0])


def test_run_target_rejects_duplicate_owned_running_pods() -> None:
    module = _load_module()
    _wire_module(
        module,
        pod_order=[
            _pod("grafana-one", "pod-one", "rs-active", "2026-08-01T00:00:03Z"),
            _pod("grafana-two", "pod-two", "rs-active", "2026-08-01T00:00:04Z"),
        ],
    )

    with pytest.raises(ValueError):
        module.run_target(module.DEFAULT_TARGETS[0])
