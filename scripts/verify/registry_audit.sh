#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_PATH="${ARTIFACT_PATH:-$REPO_ROOT/artifacts/registry_audit.json}"
REGISTRY_HOSTPORT="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
REGISTRY_URL="${REGISTRY_URL:-https://${REGISTRY_HOSTPORT}}"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-$REPO_ROOT/scripts/verify/allowed_system_images.txt}"
REQUIRED_REGISTRY_IMAGES_PATH="${REQUIRED_REGISTRY_IMAGES_PATH:-$REPO_ROOT/scripts/verify/required_registry_images.txt}"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
KIND_CONFIG_PATH="${KIND_CONFIG_PATH:-$REPO_ROOT/platform/build/kind/kind-config.yaml}"
COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
RUNTIME_DRIFT_CLASSIFICATION_PATH="${RUNTIME_DRIFT_CLASSIFICATION_PATH:-$REPO_ROOT/artifacts/runtime/runtime_drift_classification.json}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

ensure_cluster_readable || exit $?
bash "$REPO_ROOT/scripts/verify/registry_health.sh" >/dev/null

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

env \
    -u 'BASH_FUNC_kubectl%%' \
    -u 'BASH_FUNC_helm%%' \
    "$COLLECT_SCRIPT" --scope cluster --output "$tmp_dir/manifest_images.txt" >/dev/null

SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH" \
python3 - "$ARTIFACT_PATH" "$REGISTRY_URL" "$REGISTRY_HOSTPORT" "$tmp_dir/manifest_images.txt" "$ALLOWED_SYSTEM_IMAGES_PATH" "$REQUIRED_REGISTRY_IMAGES_PATH" "$KIND_CONFIG_PATH" "$COSIGN_PUBLIC_KEY_PATH" "$REGISTRY_CA_CERT_PATH" "$RUNTIME_DRIFT_CLASSIFICATION_PATH" "$REPO_ROOT" <<'PY'
from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from concurrent.futures import ThreadPoolExecutor

artifact_path = pathlib.Path(sys.argv[1])
registry_url = sys.argv[2].rstrip("/")
registry_hostport = sys.argv[3]
manifest_path = pathlib.Path(sys.argv[4])
allowed_path = pathlib.Path(sys.argv[5])
required_path = pathlib.Path(sys.argv[6])
kind_config_path = pathlib.Path(sys.argv[7])
cosign_public_key_path = pathlib.Path(sys.argv[8])
registry_ca_cert_path = pathlib.Path(sys.argv[9])
runtime_drift_classification_path = pathlib.Path(sys.argv[10])
repo_root = pathlib.Path(sys.argv[11])
registry_cert_dir_path = pathlib.Path(tempfile.mkdtemp(prefix="registry-audit-cert-dir-"))
shutil.copy2(registry_ca_cert_path, registry_cert_dir_path / "ca.crt")
registry_cert_dir = str(registry_cert_dir_path)
base_env = os.environ.copy()
registry_user = os.environ.get("THREADFORGE_REGISTRY_USER", "threadforge")
registry_password = os.environ.get("THREADFORGE_REGISTRY_PASSWORD", "threadforge-dev-password")
registry_creds = f"{registry_user}:{registry_password}"


def run(cmd: list[str], timeout_seconds: int = 30) -> str:
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False, timeout=timeout_seconds, env=base_env)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "command failed")
    return proc.stdout


def canonicalize(ref: str) -> str:
    raw = ref.strip()
    if not raw or raw.startswith("#"):
        return ""
    if "@sha256:" not in raw:
        return ""
    name, digest = raw.rsplit("@", 1)
    if ":" in name.rsplit("/", 1)[-1]:
        name = name.rsplit(":", 1)[0]
    return f"{name}@{digest.lower()}"


def unique_sorted(values: list[str]) -> list[str]:
    return sorted({value for value in values if value})


def manifest_digest_for_tag(repo: str, tag: str) -> str:
    response = run(
        [
            "curl",
            "-sS",
            "--cacert",
            str(registry_ca_cert_path),
            "-u",
            registry_creds,
            "-D",
            "-",
            "-o",
            "/dev/null",
            "-w",
            "\nHTTP_STATUS:%{http_code}\n",
            "--connect-timeout",
            "5",
            "--max-time",
            "30",
            "-H",
            "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json",
            f"{registry_url}/v2/{repo}/manifests/{tag}",
        ]
    )
    status_line = next((line for line in response.splitlines() if line.startswith("HTTP_STATUS:")), "HTTP_STATUS:000")
    status_code = status_line.split(":", 1)[1].strip()
    headers = "\n".join(line for line in response.splitlines() if not line.startswith("HTTP_STATUS:"))
    if status_code == "404":
        # Tag list can race with registry GC/retagging; treat missing tag as absent.
        return ""
    if status_code != "200":
        raise RuntimeError(f"registry manifest lookup failed for {repo}:{tag} (http={status_code})")
    for line in headers.splitlines():
        if line.lower().startswith("docker-content-digest:"):
            return line.split(":", 1)[1].strip().lower()
    raise RuntimeError(f"registry manifest digest header missing for {repo}:{tag}")


def read_kind_node_image() -> str:
    text = kind_config_path.read_text(encoding="utf-8")
    match = re.search(r"^[ \t]*image:[ \t]*(\S+)[ \t]*$", text, re.MULTILINE)
    if not match:
        raise RuntimeError(f"kind config missing node image: {kind_config_path}")
    return canonicalize(match.group(1))


def verify_signature(image_ref: str) -> bool:
    proc = subprocess.run(
        [
            "cosign",
            "verify",
            "--key",
            str(cosign_public_key_path),
            "--rekor-url",
            "https://rekor.sigstore.dev",
            image_ref,
        ],
        text=True,
        capture_output=True,
        check=False,
        timeout=45,
        env=base_env,
    )
    return proc.returncode == 0


pods_doc = json.loads(run(["kubectl", "get", "pods", "-A", "--request-timeout=30s", "-o", "json"]))
source_sha = run(["git", "-C", str(repo_root), "rev-parse", "HEAD"]).strip()
cluster_context = run(["kubectl", "config", "current-context"]).strip()
runtime_refs: list[str] = []
runtime_projection_by_digest: dict[str, str] = {}

if runtime_drift_classification_path.exists():
    try:
        drift_doc = json.loads(runtime_drift_classification_path.read_text(encoding="utf-8"))
    except Exception:
        drift_doc = {}
    for entry in drift_doc.get("entries") or []:
        if not isinstance(entry, dict):
            continue
        if not entry.get("is_internal", False) or not entry.get("is_signed", False):
            continue
        projected_ref = canonicalize(str(entry.get("effective_spec_ref") or ""))
        resolved_ref = canonicalize(str(entry.get("resolved_ref") or entry.get("image_id_ref") or ""))
        if not projected_ref or not resolved_ref:
            continue
        match = re.fullmatch(r"[^@]+@sha256:([0-9a-f]{64})", resolved_ref)
        if match:
            runtime_projection_by_digest.setdefault(match.group(1), projected_ref)

for item in pods_doc.get("items") or []:
    if not isinstance(item, dict):
        continue
    spec = item.get("spec") or {}
    if not isinstance(spec, dict):
        continue
    for field in ("initContainers", "containers"):
        for container in spec.get(field) or []:
            if not isinstance(container, dict):
                continue
            runtime_ref = canonicalize(str(container.get("image") or ""))
            match = re.fullmatch(r"[^@]+@sha256:([0-9a-f]{64})", runtime_ref)
            if match:
                runtime_ref = runtime_projection_by_digest.get(match.group(1), runtime_ref)
            runtime_refs.append(runtime_ref)

runtime_images = unique_sorted(runtime_refs)

# Supported demos render source-built images into a temporary manifest to keep
# SOURCE_MUTATION=0.  Their live Deployment is authoritative only when it is
# bound to this exact source SHA and every digest verifies with the canonical
# signing key.  This is deliberately narrower than accepting arbitrary signed
# runtime images.
dynamic_demo_images: list[str] = []
dynamic_demo_violations: list[str] = []
approved_agents = {"research-agent", "writer-agent", "attacker-agent", "rogue-agent"}
has_agents_runtime = any(
    str((item.get("metadata") or {}).get("namespace") or "") == "agents-lab"
    for item in pods_doc.get("items") or []
)
agents_doc = {"items": []}
if has_agents_runtime:
    agents_doc = json.loads(
        run(["kubectl", "get", "deployments", "-n", "agents-lab", "--request-timeout=30s", "-o", "json"])
    )
seen_agents: set[str] = set()
for deployment in agents_doc.get("items") or []:
    metadata = deployment.get("metadata") or {}
    name = str(metadata.get("name") or "")
    if name not in approved_agents:
        continue
    seen_agents.add(name)
    annotations = metadata.get("annotations") or {}
    bound_sha = str(annotations.get("threadforge.io/source-sha") or "")
    if bound_sha != source_sha:
        dynamic_demo_violations.append(f"agents-lab/{name}:source_sha={bound_sha or 'missing'}")
        continue
    containers = (((deployment.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
    for container in containers:
        ref = canonicalize(str(container.get("image") or ""))
        expected_prefix = f"{registry_hostport}/agents-lab/{name}@sha256:"
        if not ref.startswith(expected_prefix):
            dynamic_demo_violations.append(f"agents-lab/{name}:unexpected_image={ref or 'missing'}")
        elif not verify_signature(ref):
            dynamic_demo_violations.append(f"agents-lab/{name}:unsigned={ref}")
        else:
            dynamic_demo_images.append(ref)
if has_agents_runtime:
    for missing_agent in sorted(approved_agents - seen_agents):
        dynamic_demo_violations.append(f"agents-lab/{missing_agent}:deployment_missing")

manifest_images = unique_sorted(
    [canonicalize(line) for line in manifest_path.read_text().splitlines()]
    + [canonicalize(line) for line in allowed_path.read_text().splitlines()]
    + dynamic_demo_images
)
required_images = unique_sorted(
    [canonicalize(line) for line in allowed_path.read_text().splitlines()]
    + [canonicalize(line) for line in required_path.read_text().splitlines()]
)
kind_node_image = read_kind_node_image()
manifest_images = unique_sorted(manifest_images + [kind_node_image])
required_images = unique_sorted(required_images + [kind_node_image])

catalog = json.loads(run(["curl", "-fsS", "--cacert", str(registry_ca_cert_path), "-u", registry_creds, "--connect-timeout", "5", "--max-time", "30", f"{registry_url}/v2/_catalog?n=100"]))
if catalog.get("errors"):
    raise RuntimeError(f"registry catalog query failed: {catalog['errors']}")
repos = sorted(catalog.get("repositories") or [])
registry_inventory: list[dict[str, str]] = []
registry_images: set[str] = set()

def load_repo_inventory(repo: str) -> list[dict[str, str]]:
    tags_response = run(
        [
            "curl",
            "-sS",
            "--cacert",
            str(registry_ca_cert_path),
            "-u",
            registry_creds,
            "--connect-timeout",
            "5",
            "--max-time",
            "30",
            "-w",
            "\nHTTP_STATUS:%{http_code}\n",
            f"{registry_url}/v2/{repo}/tags/list?n=100",
        ]
    )
    tags_status_line = next((line for line in tags_response.splitlines() if line.startswith("HTTP_STATUS:")), "HTTP_STATUS:000")
    tags_status_code = tags_status_line.split(":", 1)[1].strip()
    if tags_status_code == "404":
        return []
    if tags_status_code != "200":
        raise RuntimeError(f"registry tags query failed for {repo} (http={tags_status_code})")
    tags_json = "\n".join(line for line in tags_response.splitlines() if not line.startswith("HTTP_STATUS:"))
    tags_doc = json.loads(tags_json or "{}")
    if tags_doc.get("errors"):
        errors = tags_doc["errors"]
        if any(isinstance(err, dict) and err.get("code") == "NAME_UNKNOWN" for err in errors):
            return []
        raise RuntimeError(f"registry tags query failed for {repo}: {errors}")
    tags = sorted(tags_doc.get("tags") or [])

    def inspect_tag(tag: str) -> dict[str, str]:
        digest = manifest_digest_for_tag(repo, tag)
        if not digest:
            return {}
        canonical_ref = f"{registry_hostport}/{repo}@{digest}"
        return {
            "repo": repo,
            "tag": tag,
            "digest": digest,
            "canonical_ref": canonical_ref,
            "tagged_ref": f"{registry_hostport}/{repo}:{tag}",
        }

    if not tags:
        return []
    with ThreadPoolExecutor(max_workers=min(8, len(tags))) as executor:
        return [entry for entry in executor.map(inspect_tag, tags) if entry]

with ThreadPoolExecutor(max_workers=min(8, max(1, len(repos)))) as executor:
    for repo_entries in executor.map(load_repo_inventory, repos):
        for entry in repo_entries:
            registry_images.add(entry["canonical_ref"])
            registry_inventory.append(entry)

runtime_set = set(runtime_images)
manifest_set = set(manifest_images)
registry_set = set(registry_images)

def inspect_manifest_ref(manifest_ref: str) -> str:
    try:
        digest = run(
            [
                "skopeo",
                "inspect",
                "--creds",
                registry_creds,
                "--tls-verify=true",
                "--cert-dir",
                registry_cert_dir,
                "--format",
                "{{.Digest}}",
                f"docker://{manifest_ref}",
            ]
        ).strip().lower()
    except RuntimeError:
        return ""
    resolved = canonicalize(f"{manifest_ref.rsplit('@', 1)[0]}@{digest}")
    if digest and canonicalize(manifest_ref) == resolved:
        return resolved
    return ""

missing_manifest_refs = sorted(manifest_set - registry_set)
if missing_manifest_refs:
    with ThreadPoolExecutor(max_workers=min(8, len(missing_manifest_refs))) as executor:
        for resolved in executor.map(inspect_manifest_ref, missing_manifest_refs):
            if resolved:
                registry_set.add(resolved)

runtime_not_in_manifests = sorted(runtime_set - manifest_set)
manifest_not_in_registry = sorted(manifest_set - registry_set)
required_image_status = {
    image_ref: {
        "digest_pinned": bool(re.fullmatch(rf"{re.escape(registry_hostport)}/[^\s]+@sha256:[0-9a-f]{{64}}", image_ref)),
        "present_in_registry": image_ref in registry_set,
    }
    for image_ref in required_images
}
required_image_violations = [
    image_ref
    for image_ref, status_entry in required_image_status.items()
    if not status_entry["digest_pinned"] or not status_entry["present_in_registry"]
]
kind_node_requirements = {
    "ref": kind_node_image,
    "digest_pinned": bool(re.fullmatch(rf"{re.escape(registry_hostport)}/[^\s]+@sha256:[0-9a-f]{{64}}", kind_node_image)),
    "present_in_registry": kind_node_image in registry_set,
    "signed": verify_signature(kind_node_image),
}
kind_node_violations = []
if not kind_node_requirements["digest_pinned"]:
    kind_node_violations.append("kind_node_image_not_digest_pinned")
if not kind_node_requirements["present_in_registry"]:
    kind_node_violations.append("kind_node_image_missing_from_registry")
if not kind_node_requirements["signed"]:
    kind_node_violations.append("kind_node_image_unsigned")
status = "PASS" if not runtime_not_in_manifests and not manifest_not_in_registry and not required_image_violations and not kind_node_violations and not dynamic_demo_violations else "FAIL"

artifact = {
    "schema_version": 1,
    "generated_at": datetime.now(tz=UTC).isoformat(timespec="seconds"),
    "source_sha": source_sha,
    "cluster_context": cluster_context,
    "status": status,
    "invariant": "runtime_subset_manifests_subset_registry",
    "required_images": required_image_status,
    "kind_node_image": kind_node_requirements,
    "counts": {
        "runtime": len(runtime_images),
        "manifests": len(manifest_images),
        "required": len(required_images),
        "registry": len(sorted(registry_set)),
        "registry_tags": len(registry_inventory),
    },
    "runtime_images": runtime_images,
    "source_bound_dynamic_demo_images": unique_sorted(dynamic_demo_images),
    "manifest_images": manifest_images,
    "registry_images": sorted(registry_set),
    "registry_inventory": registry_inventory,
    "violations": {
        "runtime_not_in_manifests": runtime_not_in_manifests,
        "manifest_not_in_registry": manifest_not_in_registry,
        "required_images": required_image_violations,
        "kind_node_image": kind_node_violations,
        "dynamic_demo_provenance": dynamic_demo_violations,
    },
}
artifact_path.parent.mkdir(parents=True, exist_ok=True)
artifact_path.write_text(json.dumps(artifact, indent=2) + "\n")

print(f"REGISTRY_RUNTIME_COUNT={len(runtime_images)}")
print(f"REGISTRY_MANIFEST_COUNT={len(manifest_images)}")
print(f"REGISTRY_AVAILABLE_COUNT={len(sorted(registry_set))}")
if status == "PASS":
    print(
        f"[PASS] registry containment audit: runtime={len(runtime_images)} manifests={len(manifest_images)} registry={len(sorted(registry_set))}"
    )
else:
    if runtime_not_in_manifests:
        print("[FAIL] registry containment audit: runtime images missing from manifests")
    if manifest_not_in_registry:
        print("[FAIL] registry containment audit: manifest images missing from registry")
    for image_ref in required_image_violations:
        print(f"[FAIL] registry containment audit: required image missing from registry: {image_ref}")
    for violation in kind_node_violations:
        print(f"[FAIL] registry containment audit: {violation}")
    for violation in dynamic_demo_violations:
        print(f"[FAIL] registry containment audit: dynamic demo provenance violation: {violation}")
    raise SystemExit(2)
PY
