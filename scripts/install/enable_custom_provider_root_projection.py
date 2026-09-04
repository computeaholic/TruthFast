#!/usr/bin/env python3
"""Stamp the custom-provider sidecar trust-root projection onto injected workloads.

ThreadForge custom-provider sidecars still expect a local root-cert file for
pilot-agent bootstrap. This helper applies the shared workload-local contract
once, at the common deployment layer, instead of patching individual apps.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass

TARGET_NAMESPACES = (
    "observability",
    "threadforge-system",
    "threadforge",
    "threadforge-test",
    "minio",
)
MOUNT_NAME = "istio-custom-root-cert"
MOUNT_PATH = "/etc/certs"
CONFIGMAP_NAME = "istio-ca-root-cert"


def _run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def _get_injector_values() -> dict:
    raw = _run(
        [
            "kubectl",
            "-n",
            "istio-system",
            "get",
            "configmap",
            "istio-sidecar-injector",
            "-o",
            "jsonpath={.data.values}",
        ],
        check=False,
    )
    if raw.returncode != 0 or not raw.stdout.strip():
        raise SystemExit("[FAIL] missing sidecar injector values")
    try:
        return json.loads(raw.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[FAIL] unable to parse injector values JSON: {exc}") from exc


def _namespace_injection_mode(namespace: str) -> str:
    raw = _run(
        [
            "kubectl",
            "get",
            "namespace",
            namespace,
            "-o",
            "jsonpath={.metadata.labels.istio-injection}",
        ],
        check=False,
    )
    if raw.returncode != 0:
        return ""
    return raw.stdout.strip()


def _json_patch_annotations(existing: dict[str, str]) -> tuple[str, str]:
    def _loads(value: str | None) -> dict[str, object]:
        if not value:
            return {}
        try:
            parsed = json.loads(value)
        except Exception:
            return {}
        if isinstance(parsed, dict):
            return parsed
        return {}

    user_volume = _loads(existing.get("sidecar.istio.io/userVolume"))
    user_volume_mount = _loads(existing.get("sidecar.istio.io/userVolumeMount"))

    user_volume.setdefault(MOUNT_NAME, {"configMap": {"name": CONFIGMAP_NAME}})
    user_volume_mount.setdefault(MOUNT_NAME, {"mountPath": MOUNT_PATH, "readOnly": True})

    return (
        json.dumps(user_volume, separators=(",", ":")),
        json.dumps(user_volume_mount, separators=(",", ":")),
    )


@dataclass(frozen=True)
class WorkloadRef:
    kind: str
    name: str
    namespace: str


def _iter_workloads(namespace: str) -> list[WorkloadRef]:
    raw = _run(
        [
            "kubectl",
            "get",
            "deploy,sts,ds",
            "-n",
            namespace,
            "-o",
            "json",
        ],
        check=False,
    )
    if raw.returncode != 0 or not raw.stdout.strip():
        return []

    try:
        doc = json.loads(raw.stdout)
    except json.JSONDecodeError:
        return []

    items = doc.get("items")
    if not isinstance(items, list):
        return []

    refs: list[WorkloadRef] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind") or "").strip()
        meta = item.get("metadata") or {}
        spec = item.get("spec") or {}
        tmpl = (spec.get("template") or {}) if isinstance(spec, dict) else {}
        tmpl_meta = tmpl.get("metadata") or {}
        annotations = tmpl_meta.get("annotations") or {}
        if not isinstance(annotations, dict):
            annotations = {}
        if annotations.get("sidecar.istio.io/inject") == "false":
            continue
        name = str(meta.get("name") or "").strip()
        if not kind or not name:
            continue
        refs.append(WorkloadRef(kind=kind, name=name, namespace=namespace))
    return refs


def _has_etc_certs_mount(namespace: str, kind: str, name: str) -> bool:
    raw = _run(
        [
            "kubectl",
            "-n",
            namespace,
            "get",
            kind.lower(),
            name,
            "-o",
            "json",
        ],
        check=False,
    )
    if raw.returncode != 0 or not raw.stdout.strip():
        return False

    try:
        doc = json.loads(raw.stdout)
    except json.JSONDecodeError:
        return False

    spec = doc.get("spec") or {}
    tmpl = spec.get("template") or {}
    tmpl_meta = tmpl.get("metadata") or {}
    annotations = tmpl_meta.get("annotations") or {}
    if not isinstance(annotations, dict):
        annotations = {}

    mounts = annotations.get("sidecar.istio.io/userVolumeMount")
    if not mounts:
        return False
    try:
        mounts_doc = json.loads(mounts)
    except Exception:
        return False
    if not isinstance(mounts_doc, dict):
        return False
    for value in mounts_doc.values():
        if isinstance(value, dict) and value.get("mountPath") == MOUNT_PATH:
            return True
    return False


def _patch_workload(namespace: str, kind: str, name: str) -> bool:
    current = _run(["kubectl", "-n", namespace, "get", kind.lower(), name, "-o", "json"], check=False)
    if current.returncode != 0 or not current.stdout.strip():
        return False

    try:
        doc = json.loads(current.stdout)
    except json.JSONDecodeError:
        return False

    spec = doc.get("spec") or {}
    tmpl = spec.get("template") or {}
    tmpl_meta = tmpl.get("metadata") or {}
    annotations = tmpl_meta.get("annotations") or {}
    if not isinstance(annotations, dict):
        annotations = {}

    if annotations.get("sidecar.istio.io/inject") == "false":
        return False
    if _has_etc_certs_mount(namespace, kind, name):
        return False

    user_volume_json, user_volume_mount_json = _json_patch_annotations(annotations)
    patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "sidecar.istio.io/userVolume": user_volume_json,
                        "sidecar.istio.io/userVolumeMount": user_volume_mount_json,
                    }
                }
            }
        }
    }

    _run(
        [
            "kubectl",
            "-n",
            namespace,
            "patch",
            kind.lower(),
            name,
            "--type=merge",
            "-p",
            json.dumps(patch, separators=(",", ":")),
        ],
        check=True,
    )
    print(
        f"[PASS] custom-provider root projection stamped: {namespace}/{kind.lower()}/{name}",
    )
    return True


def main() -> int:
    values = _get_injector_values()
    global_cfg = values.get("global", {}) if isinstance(values, dict) else {}
    provider = global_cfg.get("pilotCertProvider")
    ca_addr = global_cfg.get("caAddress")

    if provider != "custom":
        print(f"[PASS] custom-provider root projection not required (pilotCertProvider={provider!r})")
        return 0
    if ca_addr != "spire-csr.istio-system.svc:443":
        raise SystemExit("[FAIL] global.caAddress mismatch")

    patched_any = False
    for namespace in TARGET_NAMESPACES:
        if _namespace_injection_mode(namespace) not in {"enabled", ""}:
            # Namespace explicitly disabled; skip.
            continue
        for workload in _iter_workloads(namespace):
            try:
                if _patch_workload(workload.namespace, workload.kind, workload.name):
                    patched_any = True
            except subprocess.CalledProcessError as exc:
                raise SystemExit(
                    f"[FAIL] unable to stamp custom-provider root projection for "
                    f"{workload.namespace}/{workload.kind.lower()}/{workload.name}: {exc.stderr or exc.stdout or exc}"
                ) from exc

    if patched_any:
        print("[PASS] custom-provider root projection applied to injected workloads")
    else:
        print("[PASS] custom-provider root projection already converged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
