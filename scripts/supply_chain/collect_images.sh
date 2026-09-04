#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
OUTPUT_PATH=""
ALLOWED_IMAGE_PREFIX="${ALLOWED_IMAGE_PREFIX:-registry.threadforge.local:30500/}"
SCOPE="managed"
INJECTED_COLLECT_SCRIPT="${INJECTED_COLLECT_SCRIPT:-$REPO_ROOT/scripts/proof/collect_injected_images.sh}"

usage() {
  cat <<'EOF'
Usage:
    scripts/supply_chain/collect_images.sh [--output <path>] [--scope managed|cluster]

Collects canonical image references from deployment sources and emits a unique,
sorted list of required images in canonical form:
  registry.threadforge.local:30500/...@sha256:<digest>

Sources:
  - platform/deploy/**/*.yaml|yml (includes platform/deploy/infra/ and platform/deploy/gitops/)
  - kustomization.yaml and kustomization.yml under those trees
  - Helm values files (values*.yaml|yml) under those trees

Fails closed if any discovered image reference is not digest-pinned or not in
the internal registry prefix.

Scopes:
    managed: image set for strict runtime equality in managed namespaces
    cluster: broader cluster-approved set used by completeness/signature checks
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
        --scope)
            SCOPE="$2"
            shift 2
            ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
            echo "[FAIL] unknown argument: $1" >&2
      usage
            fail_policy "collect_images received unknown argument"
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 not found in PATH" >&2
    fail_system "python3 not found in PATH"
fi

if [ "$SCOPE" != "managed" ] && [ "$SCOPE" != "cluster" ]; then
    echo "[FAIL] --scope must be managed or cluster" >&2
    exit 2
fi

if [ -n "$OUTPUT_PATH" ]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
fi

tmp_out="$(mktemp)"
merged_out="$(mktemp)"
cleanup() {
    rm -f "$tmp_out" "$merged_out"
}
trap cleanup EXIT

collect_live_spirecsr_images() {
    if ! command -v kubectl >/dev/null 2>&1; then
        return 0
    fi

    if ! kubectl -n istio-system get deploy spire-csr >/dev/null 2>&1; then
        return 0
    fi

    local live_images=()
    while IFS= read -r image; do
        [ -n "$image" ] || continue
        live_images+=("$image")
    done < <(kubectl -n istio-system get deploy spire-csr -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}' 2>/dev/null || true)

    local image normalized name digest
    for image in "${live_images[@]}"; do
        if [[ "$image" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
            fail_policy "live spire-csr image not in allowed registry: $image"
        fi

        if [[ ! "$image" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]]; then
            fail_policy "live spire-csr image is not canonical digest form: $image"
        fi

        name="${image%@sha256:*}"
        digest="${image##*@sha256:}"
        digest="${digest,,}"
        normalized="${name}@sha256:${digest}"
        echo "$normalized" >> "$tmp_out"
    done
}

python3 - "$REPO_ROOT" "$ALLOWED_IMAGE_PREFIX" "$tmp_out" "$SCOPE" <<'PY'
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1])
allowed_prefix = sys.argv[2]
out_path = pathlib.Path(sys.argv[3])
scope = sys.argv[4]

try:
    import yaml  # type: ignore[import-not-found]
except Exception as exc:  # pragma: no cover
    print(f"[FAIL] PyYAML unavailable: {exc}", file=sys.stderr)
    raise SystemExit(1)

digest_re = re.compile(r"^([^\s@]+)@(?P<digest>sha256:[0-9a-fA-F]{64})$")


def normalize_digest_ref(raw_ref: str) -> tuple[str | None, str | None]:
    ref = raw_ref.strip()
    if "@" not in ref:
        return None, "image uses tag or has no digest"

    name, digest = ref.rsplit("@", 1)
    if not digest_re.match(f"{name}@{digest}"):
        return None, "image digest format is invalid"

    digest = digest.lower()
    last_segment = name.rsplit("/", 1)[-1]
    if ":" in last_segment:
        return None, "image uses mutable tag before digest"

    return f"{name}@{digest}", None


def add_ref(raw_ref: str, source: str, refs: set[str], errors: list[str]) -> None:
    ref = raw_ref.strip()
    if "{{" in ref or "}}" in ref:
        return
    if not ref:
        return
    # Policy/glob selectors are not deployable image references.
    if "*" in ref:
        return
    # Ignore non-reference tokens (e.g. "repository:").
    if "/" not in ref:
        return
    norm_ref, err = normalize_digest_ref(ref)
    if err is not None:
        errors.append(f"{source}: {err}: {raw_ref}")
        return
    ref = norm_ref
    if not ref.startswith(allowed_prefix):
        errors.append(f"{source}: image not in allowed registry: {raw_ref}")
        return
    refs.add(ref)


def walk_node(node, source: str, refs: set[str], errors: list[str]) -> None:
    if isinstance(node, dict):
        if isinstance(node.get("image"), str):
            add_ref(node["image"], source, refs, errors)

        # Helm-style image map forms.
        repo = node.get("repository")
        digest = node.get("digest")
        if isinstance(repo, str) and isinstance(digest, str) and digest.startswith("sha256:"):
            add_ref(f"{repo}@{digest}", source, refs, errors)
        elif isinstance(repo, str) and ("tag" in node or "newTag" in node):
            errors.append(f"{source}: image repository uses tag without digest")

        registry = node.get("registry")
        name = node.get("name")
        if isinstance(registry, str) and isinstance(name, str) and isinstance(digest, str) and digest.startswith("sha256:"):
            add_ref(f"{registry.rstrip('/')}/{name.lstrip('/')}@{digest}", source, refs, errors)

        # Kustomize images list entries.
        images = node.get("images")
        if isinstance(images, list):
            for idx, item in enumerate(images):
                if not isinstance(item, dict):
                    continue
                name_val = item.get("newName") or item.get("name")
                digest_val = item.get("digest")
                if isinstance(name_val, str):
                    if isinstance(digest_val, str) and digest_val.startswith("sha256:"):
                        add_ref(f"{name_val}@{digest_val}", f"{source}#images[{idx}]", refs, errors)
                    elif "newTag" in item or "tag" in item:
                        errors.append(f"{source}#images[{idx}]: kustomize image uses tag without digest")

        for value in node.values():
            walk_node(value, source, refs, errors)
    elif isinstance(node, list):
        for value in node:
            walk_node(value, source, refs, errors)


roots = [
    repo_root / "platform" / "deploy",
    repo_root / "platform" / "runtime",
    repo_root / "services",
    repo_root / "k8s",
    repo_root / "helm",
]

if scope == "cluster":
    roots.append(repo_root / "platform" / "labs" / "agent-containment" / "k8s")

excluded_path_prefixes = {
    "platform/runtime/",
    "services/",
    "k8s/",
    "helm/",
    "platform/deploy/tests/",
    "platform/deploy/debug/",
    "platform/deploy/shim/",
    "platform/deploy/platform/runtime/",
    "platform/deploy/base/",
    "platform/deploy/router/",
    "platform/deploy/overlays/",
    "platform/deploy/telemetry/",
    "platform/deploy/registry/",
    "platform/deploy/infra/buildkit/",
    "platform/deploy/infra/monitoring/",
    "platform/deploy/infra/qdrant/",
    "platform/deploy/infra/vectordb/",
    "platform/deploy/infra/registry/",
    "platform/deploy/infra/metallb/",
    "platform/deploy/infra/minio/",
    "platform/deploy/infra/identity-controller/",
    "platform/deploy/infra/spire/templates/",
    "platform/deploy/infra/spire/disabled/",
    "platform/deploy/infra/vector-router/",
    "platform/deploy/infra/observability/debug/",
    "platform/deploy/infra/debug/",
    "artifacts/",
}

excluded_exact_paths = {
    "platform/labs/agent-containment/k8s/deployments.yaml",
    "platform/deploy/infra/spire/values.yaml",
    "platform/deploy/infra/spire/spire-workload-test.yaml",
    # kyverno chart 3.x does not support digest-pinned cleanup job images via helm values;
    # the cleanup image (bitnami/kubectl) is tracked separately in allowed_system_images.txt.
    "platform/deploy/infra/kyverno/values.yaml",
}

managed_only_excluded_prefixes = {
    "platform/deploy/infra/platform/runtime/",
    "platform/deploy/infra/runtime/",
    "platform/deploy/gitops/",
    "platform/deploy/runtime/",
}

managed_only_excluded_exact_paths = {
    "platform/deploy/infra/metallb-values.yaml",
    "platform/deploy/infra/system/allowed-runtime-images.yaml",
}
files: list[pathlib.Path] = []
for root in roots:
    if not root.exists():
        continue
    files.extend(sorted(root.rglob("*.yaml")))
    files.extend(sorted(root.rglob("*.yml")))

refs: set[str] = set()
errors: list[str] = []

for path in files:
    source = str(path.relative_to(repo_root)).replace("\\", "/")
    if any(source.startswith(prefix) for prefix in excluded_path_prefixes):
        continue
    if source in excluded_exact_paths:
        continue
    if scope == "managed" and any(source.startswith(prefix) for prefix in managed_only_excluded_prefixes):
        continue
    if scope == "managed" and source in managed_only_excluded_exact_paths:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:
        errors.append(f"{path}: read error: {exc}")
        continue

    parsed = True
    try:
        docs = list(yaml.safe_load_all(text))
    except Exception:
        parsed = False
        docs = []

    if parsed:
        for doc in docs:
            if doc is None:
                continue
            walk_node(doc, source, refs, errors)

    # Fallback for templated YAML files: collect concrete image refs from text.
    for match in re.finditer(r"\bimage\s*:\s*([\"']?)([^\n\s\"'#]+)\1", text):
        token = match.group(2).strip()
        if "{{" in token or "}}" in token:
            continue
        add_ref(token, source, refs, errors)

if errors:
    for err in errors:
        print(f"[FAIL] {err}", file=sys.stderr)
    raise SystemExit(2)

if not refs:
    print("[FAIL] no image references collected from manifests", file=sys.stderr)
    raise SystemExit(2)

out_path.write_text("\n".join(sorted(refs)) + "\n", encoding="utf-8")
print(f"[collect_images] scope={scope} collected {len(refs)} canonical image references")
PY

# Keep spire-csr coverage aligned with live cluster rollouts.
# When available, merge the digest-pinned image currently deployed in istio-system.
collect_live_spirecsr_images

if [ ! -x "$INJECTED_COLLECT_SCRIPT" ]; then
    fail_system "collect_injected_images script missing or not executable: $INJECTED_COLLECT_SCRIPT"
fi

cp "$tmp_out" "$merged_out"

injector_hash_count=0
injector_image_count=0
while IFS= read -r line; do
    case "$line" in
        INJECTED_IMAGE=*)
            injected_image="${line#INJECTED_IMAGE=}"
            if [[ ! "$injected_image" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
                fail_policy "injected image is not canonical digest form: $injected_image"
            fi
            if [[ "$injected_image" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
                fail_policy "injected image not in allowed registry: $injected_image"
            fi
            echo "$injected_image" >> "$merged_out"
            injector_image_count=$((injector_image_count + 1))
            ;;
        HASH=*)
            injector_hash_count=$((injector_hash_count + 1))
            ;;
    esac
done < <("$INJECTED_COLLECT_SCRIPT")

if [ "$injector_image_count" -eq 0 ]; then
    fail_policy "collect_injected_images produced no injected images"
fi

if [ "$injector_hash_count" -eq 0 ]; then
    fail_policy "collect_injected_images produced no source hash"
fi

sort -u "$merged_out" > "$tmp_out"

if [ -n "$OUTPUT_PATH" ]; then
  cp "$tmp_out" "$OUTPUT_PATH"
  echo "[collect_images] wrote $OUTPUT_PATH"
else
  cat "$tmp_out"
fi
