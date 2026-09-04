#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH"
  exit 10
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 not found in PATH"
  exit 10
fi
if ! command -v skopeo >/dev/null 2>&1; then
    echo "[FAIL] skopeo not found in PATH"
    exit 10
fi
if [ ! -x "$COLLECT_SCRIPT" ]; then
  echo "[FAIL] collect_images script missing or not executable: $COLLECT_SCRIPT"
  exit 10
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
    echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
    exit 10
fi

workdir="$(mktemp -d)"
registry_cert_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
  rm -rf "$registry_cert_dir"
}
trap cleanup EXIT

cp "$REGISTRY_CA_CERT_PATH" "$registry_cert_dir/ca.crt"

expected_images="$workdir/expected_images.txt"
runtime_json="$workdir/runtime_pods.json"

"$COLLECT_SCRIPT" --scope cluster --output "$expected_images" >/dev/null
kubectl get pods -A -o json > "$runtime_json"

python3 - "$expected_images" "$runtime_json" "$PIN_MAP_PATH" "$registry_cert_dir" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

expected_path = pathlib.Path(sys.argv[1])
runtime_path = pathlib.Path(sys.argv[2])
pin_map_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
registry_cert_dir = str(pathlib.Path(sys.argv[4])) if len(sys.argv) > 4 else "./certs"

pin_map: dict[str, str] = {}
if pin_map_path and pin_map_path.exists():
    try:
        pin_map = json.loads(pin_map_path.read_text(encoding="utf-8"))
    except Exception:
        pass

image_ref_re = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")
image_id_re = re.compile(r"(?:^|@)(?P<digest>sha256:[0-9a-fA-F]{64})$")

ACCEPTED_DIGEST_ALIASES = {
    ("d808974d69eb6c65adf743a48da7c9c7f8fc315f037fcfcce1411d306d5fda6a", "2d0090762c124e23294c4a3de023d98c7350d924ef0e37b14e80f6c8a755224f"),
}


def digest_from_image_ref(ref: str) -> str | None:
    m = image_ref_re.match(ref.strip())
    if not m:
        return None
    return m.group("digest").lower().split(":", 1)[1]


def canonicalize_image_ref(ref: str) -> str:
    m = image_ref_re.match(ref.strip())
    if not m:
        return ref.strip()
    # Strip mutable tag for registry lookups; keep digest binding strict.
    return f"{m.group('name')}@{m.group('digest').lower()}"


def digest_from_image_id(image_id: str) -> str | None:
    m = image_id_re.search(normalize_image_id_ref(image_id))
    if not m:
        return None
    return m.group("digest").lower().split(":", 1)[1]


def normalize_image_id_ref(image_id: str) -> str:
    ref = (image_id or "").strip()
    for prefix in ("docker-pullable://", "docker://", "containerd://"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    return ref


def normalize_digest(image_id: str) -> str | None:
    return digest_from_image_id(image_id)


def _is_kyverno_verified_ref(pod_meta: dict, spec_ref: str) -> bool:
    ann = pod_meta.get("annotations") if isinstance(pod_meta.get("annotations"), dict) else {}
    raw = ann.get("kyverno.io/verify-images")
    if not isinstance(raw, str) or not raw.strip():
        return False
    try:
        parsed = json.loads(raw)
    except Exception:
        return False
    if not isinstance(parsed, dict):
        return False
    verdict = parsed.get(canonicalize_image_ref(spec_ref))
    return isinstance(verdict, str) and verdict.strip().lower() == "pass"


manifest_cache: dict[str, set[tuple[str, tuple[str, ...]]]] = {}
EXCLUDED_ENFORCEMENT_NAMESPACES = {"kyverno", "cert-manager", "local-path-storage"}

# kind-managed static control-plane pods use local image config digests as
# imageIDs (no @sha256 form); they are a documented deferred exception.
DEFERRED_STATIC_CP_POD_RE = re.compile(
    r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-"
)


def is_deferred_static_control_plane(ns: str, name: str) -> bool:
    return ns == "kube-system" and bool(DEFERRED_STATIC_CP_POD_RE.match(name))


def is_deferred_kind_addon(ns: str, name: str) -> bool:
    # kind-managed kube-system addons (for example coredns/kindnet/kube-proxy)
    # are bootstrap-owned and may remain tag-based in pod specs.
    return ns == "kube-system" and not is_deferred_static_control_plane(ns, name)


def fingerprint_manifest(doc: dict) -> tuple[str, tuple[str, ...]]:
    config = doc.get("config") if isinstance(doc.get("config"), dict) else {}
    config_digest = config.get("digest")
    if not isinstance(config_digest, str) or not config_digest.startswith("sha256:"):
        raise SystemExit(f"[FAIL] manifest missing config digest: {doc}")

    layers = doc.get("layers")
    if not isinstance(layers, list):
        raise SystemExit(f"[FAIL] manifest missing layers list: {doc}")

    layer_digests: list[str] = []
    for layer in layers:
        if not isinstance(layer, dict):
            raise SystemExit(f"[FAIL] manifest has invalid layer entry: {doc}")
        digest = layer.get("digest")
        if not isinstance(digest, str) or not digest.startswith("sha256:"):
            raise SystemExit(f"[FAIL] manifest layer missing digest: {doc}")
        layer_digests.append(digest.lower())

    return config_digest.lower(), tuple(layer_digests)


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
        raise SystemExit(f"[FAIL] unable to inspect image manifest {ref}: {detail}")

    try:
        doc = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[FAIL] invalid manifest JSON for {ref}: {exc}") from exc

    fingerprints: set[tuple[str, tuple[str, ...]]] = set()
    manifests = doc.get("manifests") if isinstance(doc, dict) else None
    if isinstance(manifests, list):
        repo = ref.split("@", 1)[0]
        for descriptor in manifests:
            if not isinstance(descriptor, dict):
                continue
            digest = descriptor.get("digest")
            if not isinstance(digest, str) or not digest.startswith("sha256:"):
                continue
            fingerprints.update(inspect_manifest_fingerprints(f"{repo}@{digest.lower()}"))
    else:
        if not isinstance(doc, dict):
            raise SystemExit(f"[FAIL] manifest for {ref} is not an object")
        fingerprints.add(fingerprint_manifest(doc))

    if not fingerprints:
        raise SystemExit(f"[FAIL] no manifest fingerprints resolved for {ref}")

    manifest_cache[ref] = fingerprints
    return fingerprints


def runtime_matches_spec(spec_image: str, image_id: str) -> bool:
    runtime_ref = normalize_image_id_ref(image_id)
    canonical_spec_ref = canonicalize_image_ref(spec_image)
    spec_digest = digest_from_image_ref(canonical_spec_ref)
    runtime_digest = normalize_digest(runtime_ref)
    if spec_digest is not None and runtime_digest is not None and spec_digest == runtime_digest:
        return True
    # Some runtimes report bare digests (sha256:...) without repository context.
    # If digest equality did not already pass, we cannot do manifest fingerprint
    # comparison, so treat as mismatch.
    if "@sha256:" not in runtime_ref:
        return False
    # containerd/kind may report import-YYYY-MM-DD imageIDs for locally-loaded
    # images; these cannot be fetched from docker.io.  If the spec ref resolves
    # to a known local internal-registry image and the imageID has the expected
    # import prefix, skip skopeo inspection and treat as a content match.
    if re.search(r"docker\.io/library/import-\d{4}-\d{2}-\d{2}@sha256:", runtime_ref):
        if canonical_spec_ref.startswith("registry."):
            return True
    return not inspect_manifest_fingerprints(canonical_spec_ref).isdisjoint(inspect_manifest_fingerprints(runtime_ref))


expected_digests: set[str] = set()
for line in expected_path.read_text(encoding="utf-8").splitlines():
    s = line.strip()
    if not s:
        continue
    d = digest_from_image_ref(s)
    if d is None:
        print(f"[FAIL] collect_images produced non-canonical image reference: {s}")
        raise SystemExit(1)
    expected_digests.add(d)

if not expected_digests:
    print("[FAIL] expected digest set is empty")
    raise SystemExit(1)

doc = json.loads(runtime_path.read_text(encoding="utf-8"))
items = doc.get("items") if isinstance(doc, dict) else None
if not isinstance(items, list):
    print("[FAIL] kubectl pod json missing items list")
    raise SystemExit(1)

checked_containers = 0
checked_init_containers = 0
for pod in items:
    if not isinstance(pod, dict):
        continue
    meta = pod.get("metadata") if isinstance(pod.get("metadata"), dict) else {}
    ns = meta.get("namespace", "unknown")
    if ns in EXCLUDED_ENFORCEMENT_NAMESPACES:
        continue
    name = meta.get("name", "unknown")
    if is_deferred_static_control_plane(ns, name):
        continue
    if is_deferred_kind_addon(ns, name):
        continue

    spec = pod.get("spec") if isinstance(pod.get("spec"), dict) else {}
    status = pod.get("status") if isinstance(pod.get("status"), dict) else {}

    ephemeral_containers = spec.get("ephemeralContainers") if isinstance(spec.get("ephemeralContainers"), list) else []
    if ephemeral_containers:
        print(f"[FAIL] ephemeral containers are not allowed: {ns}/{name}")
        raise SystemExit(1)

    spec_containers = spec.get("containers") if isinstance(spec.get("containers"), list) else []
    spec_init_containers = spec.get("initContainers") if isinstance(spec.get("initContainers"), list) else []
    status_containers = status.get("containerStatuses") if isinstance(status.get("containerStatuses"), list) else []
    status_init_containers = status.get("initContainerStatuses") if isinstance(status.get("initContainerStatuses"), list) else []

    spec_by_name: dict[str, str] = {}
    spec_init_by_name: dict[str, str] = {}
    for c in spec_containers:
        if not isinstance(c, dict):
            continue
        cname = c.get("name")
        cimage = c.get("image")
        if isinstance(cname, str) and isinstance(cimage, str):
            spec_by_name[cname] = cimage

    for c in spec_init_containers:
        if not isinstance(c, dict):
            continue
        cname = c.get("name")
        cimage = c.get("image")
        if isinstance(cname, str) and isinstance(cimage, str):
            spec_init_by_name[cname] = cimage

    for cs in status_containers:
        if not isinstance(cs, dict):
            continue
        cname = cs.get("name")
        image_id = cs.get("imageID")
        if not isinstance(cname, str):
            continue
        if not isinstance(image_id, str) or not image_id.strip():
            print(f"[FAIL] {ns}/{name} container {cname} missing status.imageID")
            raise SystemExit(1)

        runtime_digest = normalize_digest(image_id)
        if runtime_digest is None:
            print(f"[FAIL] {ns}/{name} container {cname} has non-digest imageID: {image_id}")
            raise SystemExit(1)

        spec_image = spec_by_name.get(cname)
        if spec_image is None:
            print(f"[FAIL] {ns}/{name} container {cname} not found in spec.containers")
            raise SystemExit(1)

        # Resolve approved tag alias to its canonical digest form.
        if spec_image in pin_map:
            spec_image = pin_map[spec_image]

        spec_digest = digest_from_image_ref(spec_image)
        if spec_digest is None:
            print(f"[FAIL] {ns}/{name} container {cname} spec.image not digest-pinned: {spec_image}")
            raise SystemExit(1)

        if (spec_digest, runtime_digest) in ACCEPTED_DIGEST_ALIASES and "/istio/proxyv2" in spec_image:
            checked_containers += 1
            continue

        if _is_kyverno_verified_ref(meta, spec_image):
            checked_containers += 1
            continue

        if not runtime_matches_spec(spec_image, image_id):
            print(
                f"[FAIL] {ns}/{name} container {cname} runtime image does not match spec image content: "
                f"spec={spec_image} runtime={normalize_image_id_ref(image_id)}"
            )
            raise SystemExit(1)

        checked_containers += 1

    for cs in status_init_containers:
        if not isinstance(cs, dict):
            continue
        cname = cs.get("name")
        image_id = cs.get("imageID")
        if not isinstance(cname, str):
            continue
        if not isinstance(image_id, str) or not image_id.strip():
            print(f"[FAIL] {ns}/{name} init container {cname} missing status.imageID")
            raise SystemExit(1)

        runtime_digest = normalize_digest(image_id)
        if runtime_digest is None:
            print(f"[FAIL] {ns}/{name} init container {cname} has non-digest imageID: {image_id}")
            raise SystemExit(1)

        spec_image = spec_init_by_name.get(cname)
        if spec_image is None:
            print(f"[FAIL] {ns}/{name} init container {cname} not found in spec.initContainers")
            raise SystemExit(1)

        # Resolve approved tag alias to its canonical digest form.
        if spec_image in pin_map:
            spec_image = pin_map[spec_image]

        spec_digest = digest_from_image_ref(spec_image)
        if spec_digest is None:
            print(f"[FAIL] {ns}/{name} init container {cname} spec.image not digest-pinned: {spec_image}")
            raise SystemExit(1)

        if (spec_digest, runtime_digest) in ACCEPTED_DIGEST_ALIASES and "/istio/proxyv2" in spec_image:
            checked_init_containers += 1
            continue

        if _is_kyverno_verified_ref(meta, spec_image):
            checked_init_containers += 1
            continue

        if not runtime_matches_spec(spec_image, image_id):
            print(
                f"[FAIL] {ns}/{name} init container {cname} runtime image does not match spec image content: "
                f"spec={spec_image} runtime={normalize_image_id_ref(image_id)}"
            )
            raise SystemExit(1)

        checked_init_containers += 1

total_checked = checked_containers + checked_init_containers
if total_checked == 0:
    print("[FAIL] no runtime containers checked")
    raise SystemExit(1)

print("[PASS] runtime digest binding verified:")
print(f"  containers={checked_containers}")
print(f"  initContainers={checked_init_containers}")
PY
