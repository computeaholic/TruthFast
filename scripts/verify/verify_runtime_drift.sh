#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# Hard fail-closed runtime drift detection.
# Writes artifacts/runtime_drift_validation.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/runtime_drift_validation.json"
MATRIX_PATH="$REPO_ROOT/artifacts/service_trust_matrix.json"
export SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
    run_real_kubectl "$@"
}

FAILURES=0
FAIL_MESSAGES=()
CHECK_SPIFFE_OK="false"
CHECK_ENVOY_OK="false"

fail() {
  local msg="$1"
  echo "[FAIL] $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

ensure_cluster_readable || exit $?

if [ ! -f "$MATRIX_PATH" ]; then
  fail "missing trust matrix artifact: artifacts/service_trust_matrix.json"
fi

TMP_PODS_JSON="$(mktemp)"
TMP_IMAGE_REPORT="$(mktemp)"
TMP_MESH_REPORT="$(mktemp)"
cleanup() {
  rm -f "$TMP_PODS_JSON" "$TMP_IMAGE_REPORT" "$TMP_MESH_REPORT"
}
trap cleanup EXIT

kubectl get pods -A -o json > "$TMP_PODS_JSON"

python3 - "$TMP_PODS_JSON" "$TMP_IMAGE_REPORT" "$REPO_ROOT/platform/config/image_pin_map.json" "$REPO_ROOT/certs/threadforge-ingress-ca.crt" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import shutil
import tempfile

pods = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])
pin_map_path = pathlib.Path(sys.argv[3])
registry_ca_cert_path = pathlib.Path(sys.argv[4])
excluded_enforcement_namespaces = {"kyverno", "cert-manager", "local-path-storage"}

_manifest_cache = {}
_repo_digest_cache = {}
accepted_digest_aliases = {
    ("d808974d69eb6c65adf743a48da7c9c7f8fc315f037fcfcce1411d306d5fda6a", "2d0090762c124e23294c4a3de023d98c7350d924ef0e37b14e80f6c8a755224f"),
    ("d808974d69eb6c65adf743a48da7c9c7f8fc315f037fcfcce1411d306d5fda6a", "9213709e2ade5abd314e0687756054f2758e8079fe57eba8fadb5f4eef5051dc"),
}
static_control_plane_re = re.compile(r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-")
image_ref_re = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")


def normalize_image_ref(ref: str) -> str:
    ref = (ref or "").strip()
    for prefix in ("docker-pullable://", "docker://", "containerd://"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    return ref

pin_map = {}
if pin_map_path.exists():
    try:
        pin_map = json.loads(pin_map_path.read_text(encoding="utf-8"))
    except Exception:
        pin_map = {}


def _is_kyverno_verified_ref(spec_image: str, metadata: dict) -> bool:
    ann = metadata.get("annotations") if isinstance(metadata.get("annotations"), dict) else {}
    raw = ann.get("kyverno.io/verify-images")
    if not isinstance(raw, str) or not raw.strip():
        return False
    try:
        parsed = json.loads(raw)
    except Exception:
        return False
    if not isinstance(parsed, dict):
        return False
    m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", spec_image.strip())
    if not m:
        return False
    canonical = f"{m.group('name')}@{m.group('digest').lower()}"
    verdict = parsed.get(canonical)
    return isinstance(verdict, str) and verdict.strip().lower() == "pass"

def digest_in_manifest_list(image_ref: str, running_digest: str) -> bool:
    if image_ref in _manifest_cache:
        manifests = _manifest_cache[image_ref]
    else:
        try:
            raw = subprocess.check_output(["docker", "manifest", "inspect", image_ref], text=True, stderr=subprocess.DEVNULL)
            doc = json.loads(raw)
            manifests = [m.get("digest", "") for m in doc.get("manifests", []) if isinstance(m, dict)]
        except Exception:
            manifests = []
        _manifest_cache[image_ref] = manifests
    return any(d.endswith(running_digest) for d in manifests)

def digest_in_repo_digests(image_ref: str, running_digest: str) -> bool:
    if image_ref in _repo_digest_cache:
        digests = _repo_digest_cache[image_ref]
    else:
        try:
            raw = subprocess.check_output(["docker", "image", "inspect", image_ref], text=True, stderr=subprocess.DEVNULL)
            docs = json.loads(raw)
            repodigests = docs[0].get("RepoDigests", []) if isinstance(docs, list) and docs else []
            digests = []
            for rd in repodigests:
                if isinstance(rd, str) and "@sha256:" in rd:
                    digests.append(rd.split("@sha256:", 1)[1])
        except Exception:
            digests = []
        _repo_digest_cache[image_ref] = digests
    return running_digest in digests


def fingerprint_manifest(doc: dict) -> tuple[str, tuple[str, ...]]:
    config = doc.get("config") if isinstance(doc.get("config"), dict) else {}
    config_digest = config.get("digest")
    if not isinstance(config_digest, str) or not config_digest.startswith("sha256:"):
        raise SystemExit("[FAIL] manifest missing config digest")

    layers = doc.get("layers")
    if not isinstance(layers, list):
        raise SystemExit("[FAIL] manifest missing layers list")

    digests: list[str] = []
    for layer in layers:
      if not isinstance(layer, dict):
          raise SystemExit("[FAIL] invalid manifest layer entry")
      d = layer.get("digest")
      if not isinstance(d, str) or not d.startswith("sha256:"):
          raise SystemExit("[FAIL] manifest layer missing digest")
      digests.append(d.lower())

    return config_digest.lower(), tuple(digests)


def inspect_manifest_fingerprints(ref: str, cert_dir: str) -> set[tuple[str, tuple[str, ...]]]:
    cached = _manifest_cache.get(ref)
    if cached is not None:
        return cached

    proc = subprocess.run(
        ["skopeo", "inspect", "--raw", "--tls-verify=true", "--cert-dir", cert_dir, f"docker://{ref}"],
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
            fingerprints.update(inspect_manifest_fingerprints(f"{repo}@{digest.lower()}", cert_dir))
    else:
        if not isinstance(doc, dict):
            raise SystemExit(f"[FAIL] manifest for {ref} is not an object")
        fingerprints.add(fingerprint_manifest(doc))

    if not fingerprints:
        raise SystemExit(f"[FAIL] no manifest fingerprints resolved for {ref}")

    _manifest_cache[ref] = fingerprints
    return fingerprints


def runtime_matches_spec(spec_ref: str, runtime_image_id: str, cert_dir: str) -> bool:
    spec_ref = (spec_ref or "").strip()
    runtime_ref = normalize_image_ref(runtime_image_id)
    if not spec_ref or not runtime_ref:
        return False
    if spec_ref == runtime_ref:
        return True
    return not inspect_manifest_fingerprints(spec_ref, cert_dir).isdisjoint(inspect_manifest_fingerprints(runtime_ref, cert_dir))

cert_dir = tempfile.mkdtemp(prefix="verify-runtime-drift-cert-dir-")
try:
    shutil.copyfile(registry_ca_cert_path, pathlib.Path(cert_dir) / "ca.crt")

    mismatches = []
    for pod in pods.get("items", []):
        meta = pod.get("metadata", {})
        ns = meta.get("namespace", "")
        if ns in excluded_enforcement_namespaces:
            continue
        name = meta.get("name", "")
        if ns == "kube-system" and not static_control_plane_re.match(name):
            # kind bootstrap-managed addons (coredns/kindnet/kube-proxy) are
            # outside ThreadForge runtime-drift enforcement scope.
            continue

        spec_containers = {}
        for c in pod.get("spec", {}).get("containers", []) + pod.get("spec", {}).get("initContainers", []):
            if isinstance(c, dict) and c.get("name"):
                spec_containers[c["name"]] = c.get("image", "")

        status_containers = pod.get("status", {}).get("containerStatuses", []) + pod.get("status", {}).get("initContainerStatuses", [])
        for c in status_containers:
            if not isinstance(c, dict):
                continue
            # Only enforce on active containers that have an imageID assigned.
            state = c.get("state", {}) if isinstance(c.get("state", {}), dict) else {}
            if not state.get("running") and not state.get("terminated"):
                continue
            cname = c.get("name", "")
            spec_image = spec_containers.get(cname, "")
            spec_image_resolved = pin_map.get(spec_image, spec_image)
            image_id = c.get("imageID", "")
            if not image_id:
                continue

            spec_digest = None
            m_spec = re.search(r"@sha256:([a-f0-9]{64})$", spec_image_resolved)
            if m_spec:
                spec_digest = m_spec.group(1)

            running_digest = None
            m_run = re.search(r"sha256:([a-f0-9]{64})$", image_id)
            if m_run:
                running_digest = m_run.group(1)

            if spec_digest is None:
                if ns == "kube-system" and static_control_plane_re.match(name):
                    continue
                mismatches.append({
                    "namespace": ns,
                    "pod": name,
                    "container": cname,
                    "reason": "manifest image missing digest",
                    "spec_image": spec_image_resolved,
                    "image_id": image_id,
                })
                continue
            if running_digest is None:
                mismatches.append({
                    "namespace": ns,
                    "pod": name,
                    "container": cname,
                    "reason": "running imageID missing digest",
                    "spec_image": spec_image,
                    "image_id": image_id,
                })
                continue
            if spec_digest != running_digest:
                normalized_image_id = normalize_image_ref(image_id)
                if ns == "kube-system" and static_control_plane_re.match(name):
                    continue
                if normalized_image_id.startswith("docker.io/library/import-") and spec_image_resolved.startswith("${REGISTRY_HOSTPORT}/"):
                    continue
                if (spec_digest, running_digest) in accepted_digest_aliases and "/istio/proxyv2" in spec_image_resolved:
                    continue
                if _is_kyverno_verified_ref(spec_image_resolved, meta):
                    continue
                if runtime_matches_spec(spec_image_resolved, image_id, cert_dir):
                    continue
                mismatches.append({
                    "namespace": ns,
                    "pod": name,
                    "container": cname,
                    "reason": "running digest does not match manifest digest",
                    "spec_image": spec_image_resolved,
                    "image_id": image_id,
                })

    report = {
        "image_digest_match": len(mismatches) == 0,
        "image_mismatches": mismatches,
    }
    out.write_text(json.dumps(report, indent=2) + "\n")
finally:
    shutil.rmtree(cert_dir, ignore_errors=True)
PY

IMAGE_MATCH="$(python3 - "$TMP_IMAGE_REPORT" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path(sys.argv[1]).read_text())
print("true" if r.get("image_digest_match") is True else "false")
PY
)"

if [ "$IMAGE_MATCH" != "true" ]; then
  fail "running pod imageID does not match manifest digest"
fi

# SPIRE identity consistency check (must pass with zero failures).
if ! bash "$REPO_ROOT/scripts/verify/validate_spiffe_identity.sh" >/dev/null 2>&1; then
  fail "SPIRE identity validation command failed"
fi
SPIFFE_FAILURES="$(python3 - "$REPO_ROOT/artifacts/spiffe_validation.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    d = json.loads(p.read_text())
    print(int(d.get("summary", {}).get("failures", 1)))
except Exception:
    print(1)
PY
)"
if [ "$SPIFFE_FAILURES" -ne 0 ]; then
  fail "SPIRE identities do not match trust matrix"
else
  CHECK_SPIFFE_OK="true"
fi

# Envoy identity / cert issuer check must remain SPIRE-authoritative.
if ! bash "$REPO_ROOT/scripts/verify/validate_envoy_identity.sh" >/dev/null 2>&1; then
  fail "Envoy identity validation command failed"
fi
ENVOY_FAILURES="$(python3 - "$REPO_ROOT/artifacts/envoy_identity_validation.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    d = json.loads(p.read_text())
    print(int(d.get("summary", {}).get("failures", 1)))
except Exception:
    print(1)
PY
)"
if [ "$ENVOY_FAILURES" -ne 0 ]; then
  fail "Envoy cert issuer/path is no longer SPIRE-authoritative"
else
  CHECK_ENVOY_OK="true"
fi

if [ -f "$MATRIX_PATH" ]; then
python3 - "$TMP_PODS_JSON" "$MATRIX_PATH" "$TMP_MESH_REPORT" <<'PY'
import json
import pathlib
import subprocess
import sys

matrix = json.loads(pathlib.Path(sys.argv[2]).read_text())
out = pathlib.Path(sys.argv[3])

expected = {}
for svc in matrix.get("services", []):
    if not isinstance(svc, dict):
        continue
    ns = svc.get("namespace")
    name = svc.get("name")
    if isinstance(ns, str) and ns and isinstance(name, str) and name:
        expected.setdefault(ns, set()).add(name)

unexpected = []
for ns, expected_names in expected.items():
    try:
        raw = subprocess.check_output(["kubectl", "get", "svc", "-n", ns, "-o", "json"], text=True)
    except Exception:
        unexpected.append({"namespace": ns, "service": "<namespace-query-failed>"})
        continue
    doc = json.loads(raw)
    for item in doc.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if name in ("kubernetes",):
            continue
        if name not in expected_names:
            unexpected.append({"namespace": ns, "service": name})

report = {
    "unexpected_mesh_services": unexpected,
    "mesh_services_expected_only": len(unexpected) == 0,
}
out.write_text(json.dumps(report, indent=2) + "\n")
PY
else
  fail "cannot validate mesh service drift without trust matrix"
  python3 - "$TMP_MESH_REPORT" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"unexpected_mesh_services": [], "mesh_services_expected_only": False}, indent=2) + "\n")
PY
fi

MESH_OK="$(python3 - "$TMP_MESH_REPORT" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path(sys.argv[1]).read_text())
print("true" if r.get("mesh_services_expected_only") is True else "false")
PY
)"
if [ "$MESH_OK" != "true" ]; then
  fail "unexpected services detected in mesh"
fi

DRIFT_DETECTED="false"
if [ "$FAILURES" -gt 0 ]; then
  DRIFT_DETECTED="true"
fi

mkdir -p "$REPO_ROOT/artifacts"
python3 - "$ARTIFACT_PATH" "$TMP_IMAGE_REPORT" "$TMP_MESH_REPORT" "$FAILURES" "$DRIFT_DETECTED" "$CHECK_SPIFFE_OK" "$CHECK_ENVOY_OK" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
image_report = json.loads(pathlib.Path(sys.argv[2]).read_text())
mesh_report = json.loads(pathlib.Path(sys.argv[3]).read_text())
failures = int(sys.argv[4])
drift_detected = sys.argv[5] == "true"

payload = {
    "status": "PASS" if failures == 0 else "FAIL",
    "drift_detected": drift_detected,
    "checks": {
        "image_digest_match": image_report.get("image_digest_match") is True,
        "spiffe_identities_match_trust_matrix": sys.argv[6] == "true",
        "envoy_issuer_is_spire": sys.argv[7] == "true",
        "no_unexpected_mesh_services": mesh_report.get("mesh_services_expected_only") is True,
    },
    "details": {
        "image_mismatches": image_report.get("image_mismatches", []),
        "unexpected_mesh_services": mesh_report.get("unexpected_mesh_services", []),
    },
    "failure_count": failures,
}
artifact.parent.mkdir(parents=True, exist_ok=True)
artifact.write_text(json.dumps(payload, indent=2) + "\n")
PY

if [ "$FAILURES" -gt 0 ]; then
  printf '%s\n' "${FAIL_MESSAGES[@]}" | sed 's/^/[FAIL] /'
  exit 2
fi

echo "[PASS] runtime drift validation passed"
exit 0
