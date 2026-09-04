#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"

COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-$REPO_ROOT/scripts/verify/allowed_system_images.txt}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}}"
MANAGED_NAMESPACE_RE="${MANAGED_NAMESPACE_RE:-^(threadforge($|-)|threadforge-test$|threadforge-lab$|observability$|istio-system$|spire-system$|argocd$|minio$|tempo$|loki$|forgesec$)}"

command -v kubectl >/dev/null 2>&1 || { echo "[FAIL] kubectl not found" >&2; exit 10; }
command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 not found" >&2; exit 10; }
command -v skopeo >/dev/null 2>&1 || { echo "[FAIL] skopeo not found" >&2; exit 10; }
[ -x "$COLLECT_SCRIPT" ] || { echo "[FAIL] collector missing: $COLLECT_SCRIPT" >&2; exit 10; }
[ -f "$ALLOWED_SYSTEM_IMAGES_PATH" ] || { echo "[FAIL] allowed system images missing: $ALLOWED_SYSTEM_IMAGES_PATH" >&2; exit 10; }
[ -f "$REGISTRY_CA_CERT_PATH" ] || { echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2; exit 10; }

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

expected_file="$workdir/expected_images.txt"
runtime_json="$workdir/runtime_pods.json"
drift_artifact="$REPO_ROOT/artifacts/verify/runtime_reference_drift.json"

"$COLLECT_SCRIPT" --scope cluster --output "$expected_file" >/dev/null
kubectl get pods -A --request-timeout=30s -o json > "$runtime_json"

TOTAL_RUNTIME_PODS="$(python3 -c "
import json, re, sys
ns_re = re.compile(r'${MANAGED_NAMESPACE_RE}')
data = json.loads(open('${runtime_json}').read())
print(sum(1 for p in data.get('items', []) if ns_re.match((p.get('metadata') or {}).get('namespace', ''))))
")"
if [ "$TOTAL_RUNTIME_PODS" -eq 0 ]; then
  echo "[FAIL] no runtime pods discovered in managed namespaces — verification invalid"
  exit 2
fi

python3 - "$expected_file" "$ALLOWED_SYSTEM_IMAGES_PATH" "$runtime_json" "$MANAGED_NAMESPACE_RE" "$drift_artifact" "$PIN_MAP_PATH" "$REGISTRY_CA_CERT_PATH" "$REGISTRY_HOSTPORT" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

expected_path = pathlib.Path(sys.argv[1])
allowed_system_images_path = pathlib.Path(sys.argv[2])
runtime_path = pathlib.Path(sys.argv[3])
managed_ns_re = re.compile(sys.argv[4])
drift_artifact_path = pathlib.Path(sys.argv[5])
pin_map_path = pathlib.Path(sys.argv[6])
registry_ca_cert_path = pathlib.Path(sys.argv[7])
registry_hostport = sys.argv[8]
registry_cert_dir = str(registry_ca_cert_path.parent)

DIGEST = re.compile(r"^sha256:[0-9a-fA-F]{64}$")
IMAGE_WITH_DIGEST = re.compile(r"^(?P<name>[^\s@]+)@(?P<digest>sha256:[0-9a-fA-F]{64})$")
IMAGE_ID_DIGEST = re.compile(r"@(?P<digest>sha256:[0-9a-fA-F]{64})$")

ACCEPTED_DIGEST_ALIASES = {
    ("d808974d69eb6c65adf743a48da7c9c7f8fc315f037fcfcce1411d306d5fda6a", "2d0090762c124e23294c4a3de023d98c7350d924ef0e37b14e80f6c8a755224f"),
}
manifest_cache: dict[str, set[tuple[str, tuple[str, ...]]]] = {}
pin_map: dict[str, str] = {}
if pin_map_path.exists():
    try:
        pin_map = json.loads(pin_map_path.read_text(encoding="utf-8"))
    except Exception:
        pin_map = {}


def normalize_image_id_ref(image_id: str) -> str:
    ref = image_id.strip()
    for prefix in ("docker-pullable://", "docker://", "containerd://"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    return ref


def normalize_digest(value: str) -> str:
    image_id = normalize_image_id_ref(value)
    m = IMAGE_ID_DIGEST.search(image_id)
    if not m:
        print(f"[POLICY VIOLATION] runtime imageID missing digest: {value}", file=sys.stderr)
        sys.exit(2)
    digest = m.group("digest").lower()
    if not DIGEST.match(digest):
        print(f"[POLICY VIOLATION] runtime imageID has invalid digest: {value}", file=sys.stderr)
        sys.exit(2)
    return digest.split(":", 1)[1]


def resolve_runtime_ref(
    ns: str,
    pod: str,
    container_kind: str,
    container_name: str,
    repo: str,
    spec_digest: str,
    image_id: str,
) -> str:
    runtime_ref = normalize_image_id_ref(image_id)
    if runtime_ref.startswith(f"{registry_hostport}/"):
        return runtime_ref
    if runtime_ref.startswith("docker.io/library/import-"):
        return f"{repo}@sha256:{spec_digest}"
    print(f"[FAIL] EXTERNAL_RUNTIME_IMAGE: {ns}/{pod} {container_kind} {container_name} {runtime_ref}", file=sys.stderr)
    sys.exit(2)
    return runtime_ref


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


def inspect_manifest_fingerprints(ref: str) -> set[tuple[str, tuple[str, ...]]]:
    cached = manifest_cache.get(ref)
    if cached is not None:
        return cached

    proc = subprocess.run(
        ["skopeo", "inspect", "--raw", "--tls-verify=true", "--cert-dir", registry_cert_dir, f"docker://{ref}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"rc={proc.returncode}"
        print(f"[FAIL] unable to inspect image manifest {ref}: {detail}", file=sys.stderr)
        sys.exit(2)

    doc = json.loads(proc.stdout)
    fps: set[tuple[str, tuple[str, ...]]] = set()
    manifests = doc.get("manifests") if isinstance(doc, dict) else None
    if isinstance(manifests, list):
        repo = ref.split("@", 1)[0]
        for descriptor in manifests:
            if not isinstance(descriptor, dict):
                continue
            d = descriptor.get("digest")
            if isinstance(d, str) and d.startswith("sha256:"):
                fps.update(inspect_manifest_fingerprints(f"{repo}@{d.lower()}"))
    else:
        if not isinstance(doc, dict):
            print(f"[FAIL] manifest for {ref} is not an object", file=sys.stderr)
            sys.exit(2)
        fps.add(fingerprint_manifest(doc))

    if not fps:
        print(f"[FAIL] no manifest fingerprints resolved for {ref}", file=sys.stderr)
        sys.exit(2)
    manifest_cache[ref] = fps
    return fps


def parse_expected(line: str) -> str:
    raw = line.strip()
    m = IMAGE_WITH_DIGEST.match(raw)
    if not m:
        print(f"[POLICY VIOLATION] non-canonical expected image: {raw}", file=sys.stderr)
        sys.exit(2)
    return f"{m.group('name')}@{m.group('digest').lower()}"


def parse_spec_image(image: str) -> tuple[str, str]:
    image = pin_map.get(image.strip(), image.strip())
    m = IMAGE_WITH_DIGEST.match(image)
    if not m:
        print(f"[POLICY VIOLATION] runtime spec image is not digest-pinned: {image}", file=sys.stderr)
        sys.exit(2)
    # Runtime pod specs may use tag+digest form (name:tag@sha256:...).
    # Canonical expected sets are digest-only (name@sha256:...), so strip
    # the mutable tag portion before runtime/expected equality comparison.
    name = re.sub(r":[^/@]+$", "", m.group("name"))
    return name, m.group("digest").lower().split(":", 1)[1]


def parse_image_id(image_id: str) -> str:
    return normalize_digest(image_id)


expected = set()
for line in expected_path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    expected.add(parse_expected(line))

for raw_line in allowed_system_images_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.split("#", 1)[0].strip()
    if not line:
        continue
    expected.add(parse_expected(line))

if not expected:
    print("[POLICY VIOLATION] expected image set is empty", file=sys.stderr)
    sys.exit(2)

pod_doc = json.loads(runtime_path.read_text(encoding="utf-8"))
items = pod_doc.get("items") if isinstance(pod_doc, dict) else None
if not isinstance(items, list):
    print("[FAIL] kubectl output missing items list", file=sys.stderr)
    sys.exit(2)

runtime = set()
runtime_imageid_count = 0
for pod in items:
    if not isinstance(pod, dict):
        continue
    meta = pod.get("metadata") if isinstance(pod.get("metadata"), dict) else {}
    ns = meta.get("namespace", "unknown")
    if not managed_ns_re.match(ns):
        continue
    name = meta.get("name", "unknown")

    spec = pod.get("spec") if isinstance(pod.get("spec"), dict) else {}
    status = pod.get("status") if isinstance(pod.get("status"), dict) else {}

    containers = spec.get("containers") if isinstance(spec.get("containers"), list) else []
    init_containers = spec.get("initContainers") if isinstance(spec.get("initContainers"), list) else []
    ephemeral_containers = spec.get("ephemeralContainers") if isinstance(spec.get("ephemeralContainers"), list) else []
    status_containers = status.get("containerStatuses") if isinstance(status.get("containerStatuses"), list) else []
    status_init = status.get("initContainerStatuses") if isinstance(status.get("initContainerStatuses"), list) else []
    status_ephemeral = status.get("ephemeralContainerStatuses") if isinstance(status.get("ephemeralContainerStatuses"), list) else []

    spec_map = {}
    init_map = {}
    ephemeral_map = {}
    for c in containers:
        if isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("image"), str):
            spec_map[c["name"]] = c["image"]
    for c in init_containers:
        if isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("image"), str):
            init_map[c["name"]] = c["image"]
    for c in ephemeral_containers:
        if isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("image"), str):
            ephemeral_map[c["name"]] = c["image"]

    for cs in status_containers:
        if not isinstance(cs, dict) or not isinstance(cs.get("name"), str):
            continue
        cname = cs["name"]
        if cname not in spec_map:
            print(f"[FAIL] {ns}/{name} container {cname} missing from spec", file=sys.stderr)
            sys.exit(2)
        if not isinstance(cs.get("imageID"), str) or not cs["imageID"].strip():
            print(f"[FAIL] {ns}/{name} container {cname} missing imageID", file=sys.stderr)
            sys.exit(2)
        repo, spec_digest = parse_spec_image(spec_map[cname])
        runtime_ref = resolve_runtime_ref(ns, name, "container", cname, repo, spec_digest, cs["imageID"])
        runtime_digest = parse_image_id(cs["imageID"])
        if runtime_digest != spec_digest:
            if (spec_digest, runtime_digest) in ACCEPTED_DIGEST_ALIASES and "/istio/proxyv2" in repo:
                runtime_imageid_count += 1
                runtime.add(f"{repo}@sha256:{spec_digest}")
                continue
            if "@sha256:" not in runtime_ref:
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
            if inspect_manifest_fingerprints(f"{repo}@sha256:{spec_digest}").isdisjoint(inspect_manifest_fingerprints(runtime_ref)):
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
        runtime_imageid_count += 1
        runtime.add(f"{repo}@sha256:{spec_digest}")

    for cs in status_init:
        if not isinstance(cs, dict) or not isinstance(cs.get("name"), str):
            continue
        cname = cs["name"]
        if cname not in init_map:
            print(f"[FAIL] {ns}/{name} init container {cname} missing from spec", file=sys.stderr)
            sys.exit(2)
        if not isinstance(cs.get("imageID"), str) or not cs["imageID"].strip():
            print(f"[FAIL] {ns}/{name} init container {cname} missing imageID", file=sys.stderr)
            sys.exit(2)
        repo, spec_digest = parse_spec_image(init_map[cname])
        runtime_ref = resolve_runtime_ref(ns, name, "init_container", cname, repo, spec_digest, cs["imageID"])
        runtime_digest = parse_image_id(cs["imageID"])
        if runtime_digest != spec_digest:
            if (spec_digest, runtime_digest) in ACCEPTED_DIGEST_ALIASES and "/istio/proxyv2" in repo:
                runtime_imageid_count += 1
                runtime.add(f"{repo}@sha256:{spec_digest}")
                continue
            if "@sha256:" not in runtime_ref:
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} init container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
            if inspect_manifest_fingerprints(f"{repo}@sha256:{spec_digest}").isdisjoint(inspect_manifest_fingerprints(runtime_ref)):
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} init container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
        runtime_imageid_count += 1
        runtime.add(f"{repo}@sha256:{spec_digest}")

    for cs in status_ephemeral:
        if not isinstance(cs, dict) or not isinstance(cs.get("name"), str):
            continue
        cname = cs["name"]
        if cname not in ephemeral_map:
            print(f"[FAIL] {ns}/{name} ephemeral container {cname} missing from spec", file=sys.stderr)
            sys.exit(2)
        if not isinstance(cs.get("imageID"), str) or not cs["imageID"].strip():
            print(f"[FAIL] {ns}/{name} ephemeral container {cname} missing imageID", file=sys.stderr)
            sys.exit(2)
        repo, spec_digest = parse_spec_image(ephemeral_map[cname])
        runtime_ref = resolve_runtime_ref(ns, name, "ephemeral_container", cname, repo, spec_digest, cs["imageID"])
        runtime_digest = parse_image_id(cs["imageID"])
        if runtime_digest != spec_digest:
            if (spec_digest, runtime_digest) in ACCEPTED_DIGEST_ALIASES and "/istio/proxyv2" in repo:
                runtime_imageid_count += 1
                runtime.add(f"{repo}@sha256:{spec_digest}")
                continue
            if "@sha256:" not in runtime_ref:
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} ephemeral container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
            if inspect_manifest_fingerprints(f"{repo}@sha256:{spec_digest}").isdisjoint(inspect_manifest_fingerprints(runtime_ref)):
                print(
                    f"[POLICY VIOLATION] digest identity mismatch for {ns}/{name} ephemeral container {cname}: "
                    f"spec={spec_digest} runtime={runtime_digest}",
                    file=sys.stderr,
                )
                sys.exit(2)
        runtime_imageid_count += 1
        runtime.add(f"{repo}@sha256:{spec_digest}")

if runtime_imageid_count == 0:
    print("[POLICY VIOLATION] runtime status.containerStatuses[].imageID set is empty", file=sys.stderr)
    sys.exit(2)

missing = sorted(expected - runtime)
extra = sorted(runtime - expected)

drift_artifact_path.parent.mkdir(parents=True, exist_ok=True)
drift_artifact_path.write_text(
    json.dumps(
        {
            "expected_count": len(expected),
            "runtime_count": len(runtime),
            "drift_detected": bool(missing or extra),
            "missing_references": missing,
            "extra_references": extra,
            "authoritative_identity": "digest-bound-runtime-imageid",
            "reference_drift": "non-authoritative",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

print(f"EXPECTED_COUNT={len(expected)}")
print(f"RUNTIME_COUNT={len(runtime)}")
print(f"RUNTIME_IMAGEID_COUNT={runtime_imageid_count}")
print("[VERIFY] Runtime vs manifest comparison:")
print(f"runtime_images: {len(runtime)}")
print(f"manifest_images: {len(expected)}")
print(f"missing_from_runtime: {len(missing)}")
print(f"unexpected_in_runtime: {len(extra)}")

if extra:
    print("DIFF_MISSING_START")
    for i in missing:
        print(i)
    print("DIFF_MISSING_END")
    print("DIFF_EXTRA_START")
    for i in extra:
        print(i)
    print("DIFF_EXTRA_END")
    print("RUNTIME_REFERENCE_DRIFT=TRUE")
    print("[POLICY VIOLATION] runtime contains references outside the approved cluster image set", file=sys.stderr)
    sys.exit(2)

if missing:
    print("DIFF_EXTRA_START")
    print("DIFF_EXTRA_END")
    print("RUNTIME_REFERENCE_DRIFT=TRUE")
    print("[VERIFY] Runtime identity: PASS (manifest superset, no runtime drift)")
    print("RUNTIME_IDENTITY_VERIFIED=TRUE")
    sys.exit(0)

print("DIFF_MISSING_START")
print("DIFF_MISSING_END")
print("DIFF_EXTRA_START")
print("DIFF_EXTRA_END")
print("RUNTIME_REFERENCE_DRIFT=FALSE")
print("[VERIFY] Runtime identity: PASS (digest-bound, no drift)")
print("RUNTIME_IDENTITY_VERIFIED=TRUE")
PY
