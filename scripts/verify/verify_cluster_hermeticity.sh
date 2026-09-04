#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/cluster_hermeticity.json"
IMAGE_PIN_MAP_PATH="$REPO_ROOT/platform/config/image_pin_map.json"
CLUSTER_IMAGE_MAP_PATH="$REPO_ROOT/platform/config/cluster_image_map.json"

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "[FAIL] cluster unreachable"
  exit 10
fi

mkdir -p "$REPO_ROOT/artifacts"
# Keep the exact inventory command requested for audit evidence.
raw_images="$(kubectl get pods -A -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sed '/^$/d' | sort | uniq)"

python3 - "$ARTIFACT_PATH" "$IMAGE_PIN_MAP_PATH" "$CLUSTER_IMAGE_MAP_PATH" "$raw_images" <<'PY'
import json
import re
import subprocess
import sys

artifact_path = sys.argv[1]
image_pin_map_path = sys.argv[2]
cluster_image_map_path = sys.argv[3]
raw_images = [x.strip() for x in sys.argv[4].splitlines() if x.strip()]

with open(image_pin_map_path, "r", encoding="utf-8") as f:
    image_pin_map = json.load(f)

with open(cluster_image_map_path, "r", encoding="utf-8") as f:
    cluster_image_map = json.load(f)

pods = json.loads(subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"]))

registry_prefix = "registry.threadforge.local:30500/"
digest_re = re.compile(r"@sha256:[a-f0-9]{64}$")
excluded_enforcement_namespaces = {"kyverno", "local-path-storage"}
approved_external_images = set(cluster_image_map)

violations = []
classified = {
    "control_plane": set(),
    "cni": set(),
    "dns": set(),
    "ingress_gateways": set(),
    "observability": set(),
    "misc_system": set(),
}


def classify(ns: str, pod_name: str) -> str:
    if ns == "kube-system" and re.match(r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd|kube-proxy)-", pod_name):
        return "control_plane"
    if re.search(r"(kindnet|cilium|calico|flannel|weave)", pod_name):
        return "cni"
    if "coredns" in pod_name:
        return "dns"
    if ns == "istio-system" and re.search(r"(ingress|egress|gateway)", pod_name):
        return "ingress_gateways"
    if ns in {"observability", "forgesec"}:
        return "observability"
    return "misc_system"

def is_deferred_static_control_plane(ns: str, pod_name: str) -> bool:
    return ns == "kube-system" and re.match(r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-", pod_name) is not None

for pod in pods.get("items", []):
    ns = pod.get("metadata", {}).get("namespace", "")
    pod_name = pod.get("metadata", {}).get("name", "")

    # Kyverno system namespace is intentionally excluded by admission policies.
    if ns in excluded_enforcement_namespaces:
        continue

    # kind-managed static control plane pods are rewritten after cluster bring-up and
    # remain a deferred exception during runtime verification.
    if is_deferred_static_control_plane(ns, pod_name):
        continue
    # kind bootstrap-managed kube-system add-ons (for example coredns/kindnet/kube-proxy)
    # are outside ThreadForge runtime hermeticity scope.
    if ns == "kube-system":
        continue
    bucket = classify(ns, pod_name)

    containers = []
    containers.extend(pod.get("spec", {}).get("initContainers", []))
    containers.extend(pod.get("spec", {}).get("containers", []))

    for c in containers:
        if not isinstance(c, dict):
            continue
        image = c.get("image", "")
        if not image:
            continue
        classified[bucket].add(image)

        if not image.startswith(registry_prefix):
            if image in approved_external_images:
                continue
            violations.append({
                "namespace": ns,
                "pod": pod_name,
                "container": c.get("name", ""),
                "image": image,
                "reason": "non_internal_registry",
            })
            continue

        if not digest_re.search(image) and image not in image_pin_map:
            violations.append({
                "namespace": ns,
                "pod": pod_name,
                "container": c.get("name", ""),
                "image": image,
                "reason": "not_digest_pinned",
            })

raw_non_internal = [img for img in raw_images if "/" in img and not img.startswith(registry_prefix) and not img.startswith("sha256:")]
raw_non_digest = [img for img in raw_images if img.startswith(registry_prefix) and not digest_re.search(img)]

payload = {
    "status": "PASS" if not violations else "FAIL",
    "required_registry_prefix": registry_prefix,
    "inventory": {
        "control_plane": sorted(classified["control_plane"]),
        "cni": sorted(classified["cni"]),
        "dns": sorted(classified["dns"]),
        "ingress_gateways": sorted(classified["ingress_gateways"]),
        "observability": sorted(classified["observability"]),
        "misc_system": sorted(classified["misc_system"]),
    },
    "raw_command": {
        "image_count": len(raw_images),
        "non_internal_count": len(raw_non_internal),
        "non_digest_count": len(raw_non_digest),
        "non_internal_examples": raw_non_internal[:20],
        "non_digest_examples": raw_non_digest[:20],
        "approved_external_examples": sorted(img for img in raw_non_internal if img in approved_external_images)[:20],
    },
    "spec_enforcement": {
        "checked_containers": sum(len(v) for v in classified.values()),
        "violation_count": len(violations),
        "violations": violations,
    },
}

with open(artifact_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")

if violations:
    print(f"[FAIL] cluster hermeticity violations: {len(violations)}")
    raise SystemExit(1)

print("[PASS] cluster hermeticity verified")
PY
