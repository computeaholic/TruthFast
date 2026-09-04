#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_IMAGES_PATH="${RUNTIME_IMAGES_PATH:-$REPO_ROOT/artifacts/runtime/runtime_images.txt}"
RUNTIME_RESOLUTION_PATH="${RUNTIME_RESOLUTION_PATH:-$REPO_ROOT/artifacts/runtime/runtime_image_resolution.json}"
CLASSIFICATION_PATH="${CLASSIFICATION_PATH:-$REPO_ROOT/artifacts/runtime/runtime_drift_classification.json}"
REPORT_PATH="${REPORT_PATH:-$REPO_ROOT/artifacts/runtime/runtime_drift_report.json}"
SIGNED_IMAGES_PATH="${SIGNED_IMAGES_PATH:-$REPO_ROOT/artifacts/proof/signed_images.txt}"
SIGNATURE_VERIFY_SCRIPT="${SIGNATURE_VERIFY_SCRIPT:-$REPO_ROOT/scripts/verify/verify_signatures.sh}"
CLASSIFY_DRIFT_PROJECTION_ONLY="${CLASSIFY_DRIFT_PROJECTION_ONLY:-false}"
INTERNAL_PREFIX="${INTERNAL_PREFIX:-registry.threadforge.local:30500/}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"

for cmd in kubectl jq python3 skopeo; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[FAIL] required command not found in PATH: $cmd" >&2
    exit 10
  fi
done
if [ ! -x "$SIGNATURE_VERIFY_SCRIPT" ]; then
  echo "[FAIL] signature verification script missing or not executable: $SIGNATURE_VERIFY_SCRIPT" >&2
  exit 10
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
    echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2
    exit 10
fi

mkdir -p "$(dirname "$RUNTIME_IMAGES_PATH")" "$(dirname "$RUNTIME_RESOLUTION_PATH")" "$(dirname "$CLASSIFICATION_PATH")" "$(dirname "$REPORT_PATH")"

bash "$REPO_ROOT/scripts/debug/dump_runtime_images.sh" "$RUNTIME_IMAGES_PATH" >/dev/null
bash "$REPO_ROOT/scripts/debug/resolve_image_digests.sh" "$RUNTIME_RESOLUTION_PATH" >/dev/null

if [ "$CLASSIFY_DRIFT_PROJECTION_ONLY" != "true" ] && [ ! -f "$SIGNED_IMAGES_PATH" ]; then
  bash "$SIGNATURE_VERIFY_SCRIPT" >/dev/null
fi
if [ "$CLASSIFY_DRIFT_PROJECTION_ONLY" != "true" ] && [ ! -f "$SIGNED_IMAGES_PATH" ]; then
  echo "[FAIL] signature verification artifact missing after verification: $SIGNED_IMAGES_PATH" >&2
  exit 2
fi

python3 - "$RUNTIME_RESOLUTION_PATH" "$SIGNED_IMAGES_PATH" "$CLASSIFICATION_PATH" "$REPORT_PATH" "$INTERNAL_PREFIX" "$PIN_MAP_PATH" "$REGISTRY_CA_CERT_PATH" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import shutil
import tempfile

resolution_path = pathlib.Path(sys.argv[1])
signed_images_path = pathlib.Path(sys.argv[2])
classification_path = pathlib.Path(sys.argv[3])
report_path = pathlib.Path(sys.argv[4])
internal_prefix = sys.argv[5]
pin_map_path = pathlib.Path(sys.argv[6])
registry_ca_cert_path = pathlib.Path(sys.argv[7])
registry_cert_dir = str(registry_ca_cert_path.parent)
sys.path.insert(0, str(resolution_path.parents[2]))
from scripts.debug.runtime_drift_policy import classify_runtime_projection

resolution = json.loads(resolution_path.read_text(encoding="utf-8"))
entries = resolution.get("entries") if isinstance(resolution, dict) else None
if not isinstance(entries, list):
    raise SystemExit("runtime resolution artifact missing entries list")

if os.environ.get("CLASSIFY_DRIFT_PROJECTION_ONLY") == "true":
    signed_refs = set()
else:
    signed_refs = {
        line.strip()
        for line in signed_images_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }

classified = {
    "workload_container": [],
    "init_container": [],
    "istio_sidecar": [],
    "spire_component": [],
    "debug/test_workload": [],
    "mirrored_upstream": [],
}
unpinned_images = []
external_images = []
unsigned_images = []
unexplained_images = []
unknown_classifications = []
annotated_entries = []
manifest_child_cache = {}
image_with_digest_re = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")
static_control_plane_re = re.compile(r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-")

pin_map = {}
if pin_map_path.exists():
    try:
        pin_map = json.loads(pin_map_path.read_text(encoding="utf-8"))
    except Exception:
        pin_map = {}


def repo_tail(image: str) -> str:
    ref = (image or "").strip()
    if "@" in ref:
        ref = ref.split("@", 1)[0]
    if ref.startswith(internal_prefix):
        ref = ref[len(internal_prefix):]
    return ref


def classify(entry: dict) -> str:
    image = str(entry.get("image") or "")
    container_name = str(entry.get("container_name") or "")
    repo = repo_tail(image)
    repo_lower = repo.lower()
    container_lower = container_name.lower()
    if container_lower == "istio-proxy" or repo_lower.startswith("istio/proxyv2"):
        return "istio_sidecar"
    if repo_lower.startswith("spiffe/") or repo_lower.startswith("spire-") or "/spire-" in repo_lower or container_lower.startswith("spire"):
        return "spire_component"
    if repo_lower.startswith("mirror/"):
        return "mirrored_upstream"
    if any(token in repo_lower for token in ("busybox", "curlimages/curl", "/curl", "library/curl")):
        return "debug/test_workload"
    if entry.get("container_type") == "init_container":
        return "init_container"
    if entry.get("container_type") == "container":
        return "workload_container"
    return "unknown"


def fingerprint_manifest(doc: dict) -> tuple[str, tuple[str, ...]]:
    config = doc.get("config") if isinstance(doc.get("config"), dict) else {}
    config_digest = config.get("digest")
    if not isinstance(config_digest, str) or not config_digest.startswith("sha256:"):
        print("[FAIL] manifest missing config digest", file=sys.stderr)
        sys.exit(2)
    layers = doc.get("layers")
    if not isinstance(layers, list):
        print("[FAIL] manifest missing layers list", file=sys.stderr)
        sys.exit(2)
    digests: list[str] = []
    for layer in layers:
        if not isinstance(layer, dict):
            print("[FAIL] invalid manifest layer entry", file=sys.stderr)
            sys.exit(2)
        d = layer.get("digest")
        if not isinstance(d, str) or not d.startswith("sha256:"):
            print("[FAIL] manifest layer missing digest", file=sys.stderr)
            sys.exit(2)
        digests.append(d.lower())
    return config_digest.lower(), tuple(digests)


def is_attestation_descriptor(descriptor: dict) -> bool:
    if not isinstance(descriptor, dict):
        return False
    platform = descriptor.get("platform")
    if isinstance(platform, dict):
        arch = str(platform.get("architecture") or "").lower()
        os_name = str(platform.get("os") or "").lower()
        if arch == "unknown" and os_name == "unknown":
            return True
    annotations = descriptor.get("annotations")
    if isinstance(annotations, dict):
        if str(annotations.get("vnd.docker.reference.type") or "").lower() == "attestation-manifest":
            return True
    return False


def inspect_manifest_fingerprints(ref: str) -> set[tuple[str, tuple[str, ...]]]:
    cached = manifest_child_cache.get(ref)
    if cached is not None:
        return cached

    proc = subprocess.run(
        ["skopeo", "inspect", "--raw", "--tls-verify=true", "--cert-dir", registry_cert_dir, f"docker://{ref}"],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"rc={proc.returncode}"
        print(f"[FAIL] unable to inspect image manifest {ref}: {detail}", file=sys.stderr)
        sys.exit(2)

    try:
        doc = json.loads(proc.stdout)
    except Exception as exc:
        print(f"[FAIL] invalid manifest JSON for {ref}: {exc}", file=sys.stderr)
        sys.exit(2)

    fingerprints: set[tuple[str, tuple[str, ...]]] = set()
    manifests = doc.get("manifests") if isinstance(doc, dict) else None
    if isinstance(manifests, list):
        repo = ref.split("@", 1)[0]
        for descriptor in manifests:
            if not isinstance(descriptor, dict) or is_attestation_descriptor(descriptor):
                continue
            digest = descriptor.get("digest")
            if not isinstance(digest, str) or not digest.startswith("sha256:"):
                continue
            fingerprints.update(inspect_manifest_fingerprints(f"{repo}@{digest.lower()}"))
    else:
        if not isinstance(doc, dict):
            print(f"[FAIL] manifest for {ref} is not an object", file=sys.stderr)
            sys.exit(2)
        fingerprints.add(fingerprint_manifest(doc))

    if not fingerprints:
        print(f"[FAIL] no manifest fingerprints resolved for {ref}", file=sys.stderr)
        sys.exit(2)

    manifest_child_cache[ref] = fingerprints
    return fingerprints


def runtime_matches_spec(spec_ref: str, runtime_ref: str) -> bool:
    if not spec_ref or not runtime_ref:
        return False
    return classify_runtime_projection(
        spec_ref,
        runtime_ref,
        inspect_manifest_fingerprints(spec_ref),
        inspect_manifest_fingerprints(runtime_ref),
        internal_prefix,
    ) in {"exact_digest", "manifest_projection"}


registry_cert_dir = tempfile.mkdtemp(prefix="classify-drift-cert-dir-")
try:
    shutil.copyfile(registry_ca_cert_path, pathlib.Path(registry_cert_dir) / "ca.crt")

    for raw_entry in entries:
        if not isinstance(raw_entry, dict):
            continue
        entry = dict(raw_entry)
        image = str(entry.get("image") or "")
        resolved_ref = str(entry.get("resolved_ref") or "")
        spec_ref = str(entry.get("spec_canonical_ref") or "")
        spec_digest = str(entry.get("spec_digest") or "")
        resolved_digest = str(entry.get("resolved_digest") or "")
        image_id_ref = str(entry.get("image_id_ref") or "")
        effective_spec_ref = spec_ref
        effective_spec_digest = spec_digest
        if (not effective_spec_ref or not effective_spec_digest) and image in pin_map:
            mapped = str(pin_map.get(image) or "").strip()
            m = image_with_digest_re.match(mapped)
            if m:
                effective_spec_ref = f"{m.group('name')}@{m.group('digest').lower()}"
                effective_spec_digest = m.group("digest").lower()

        is_deferred_static_control_plane = (
            entry.get("namespace") == "kube-system"
            and isinstance(entry.get("pod"), str)
            and static_control_plane_re.match(str(entry.get("pod"))) is not None
        )
        is_kube_system_addon = (
            entry.get("namespace") == "kube-system"
            and not is_deferred_static_control_plane
        )
        is_local_path_provisioner = entry.get("namespace") == "local-path-storage"
        is_kind_import_alias = image_id_ref.startswith("docker.io/library/import-")

        is_pinned = "@sha256:" in image or bool(effective_spec_digest)
        resolution_kind = "missing_digest"
        if resolved_digest and effective_spec_digest and resolved_digest == effective_spec_digest:
            resolution_kind = "exact_digest"
        elif resolved_ref and effective_spec_ref and runtime_matches_spec(effective_spec_ref, resolved_ref):
            resolution_kind = "manifest_projection"
        elif resolved_digest and is_kind_import_alias and effective_spec_ref.startswith(internal_prefix):
            resolution_kind = "kind_import_alias"
        elif resolved_digest:
            resolution_kind = "unexplained_runtime_digest"

        is_internal = bool(effective_spec_ref) and effective_spec_ref.startswith(internal_prefix) and resolution_kind in {"exact_digest", "manifest_projection", "kind_import_alias"}
        is_signed = effective_spec_ref in signed_refs and resolution_kind in {"exact_digest", "manifest_projection", "kind_import_alias"}
        classification = classify(entry)
        is_deferred_exception = (
            is_deferred_static_control_plane
            or is_kube_system_addon
            or is_local_path_provisioner
            or entry.get("namespace") == "kyverno"
            or (is_kind_import_alias and effective_spec_ref.startswith(internal_prefix))
        )

        entry["classification"] = classification
        entry["is_pinned"] = is_pinned
        entry["is_internal"] = is_internal
        entry["is_signed"] = is_signed
        entry["resolution_kind"] = resolution_kind
        entry["effective_spec_ref"] = effective_spec_ref
        entry["effective_spec_digest"] = effective_spec_digest
        entry["is_deferred_exception"] = is_deferred_exception
        entry["image_id_external_name"] = bool(image_id_ref) and not image_id_ref.startswith(internal_prefix)
        annotated_entries.append(entry)

        if not is_pinned and not is_deferred_exception:
            unpinned_images.append(entry)
        if not is_internal and not is_deferred_exception:
            external_images.append(entry)
        if (
            resolved_ref
            and not is_signed
            and not is_deferred_exception
            and os.environ.get("CLASSIFY_DRIFT_PROJECTION_ONLY") != "true"
        ):
            unsigned_images.append(entry)
        if resolution_kind == "unexplained_runtime_digest" and not is_deferred_exception:
            unexplained_images.append(entry)
        if classification == "unknown":
            unknown_classifications.append(entry)
        elif classification in classified:
            classified[classification].append(entry)
finally:
    shutil.rmtree(registry_cert_dir, ignore_errors=True)

classification_payload = {
    "total_runtime_images": len(annotated_entries),
    "entries": annotated_entries,
    "classified": classified,
    "unexplained": unexplained_images,
    "unknown": unknown_classifications,
}
classification_path.write_text(json.dumps(classification_payload, indent=2) + "\n", encoding="utf-8")

report = {
    "total_runtime_images": len(annotated_entries),
    "unpinned_images": unpinned_images,
    "external_images": external_images,
    "unsigned_images": unsigned_images,
    "unexplained_images": unexplained_images,
    "unknown_classifications": unknown_classifications,
    "classified": classified,
}
report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

violations = False
for entry in unpinned_images:
    print(f"[FAIL] UNPINNED_RUNTIME_IMAGE: {entry['namespace']}/{entry['pod']} {entry['container_name']} {entry['image']}")
    violations = True
for entry in external_images:
    target = entry.get("resolved_ref") or entry.get("image")
    print(f"[FAIL] EXTERNAL_RUNTIME_IMAGE: {entry['namespace']}/{entry['pod']} {entry['container_name']} {target}")
    violations = True
for entry in unsigned_images:
    print(f"[FAIL] UNSIGNED_RUNTIME_IMAGE: {entry['namespace']}/{entry['pod']} {entry['container_name']} {entry['resolved_ref']}")
    violations = True
for entry in unexplained_images:
    print(f"[FAIL] UNEXPLAINED_RUNTIME_DRIFT: {entry['namespace']}/{entry['pod']} {entry['container_name']} imageID={entry['image_id_ref']} spec={entry['spec_canonical_ref']}")
    violations = True
for entry in unknown_classifications:
    print(f"[FAIL] UNKNOWN_RUNTIME_DRIFT: {entry['namespace']}/{entry['pod']} {entry['container_name']} {entry['image']}")
    violations = True

if violations:
    raise SystemExit(2)

print(f"[PASS] runtime drift fully classified ({len(annotated_entries)} runtime images, 0 violations)")
PY
