#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER_NAME="${BUILDER_NAME:-threadforge-builder}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
SMOKE_IMAGE="${SMOKE_IMAGE:-registry.threadforge.local:30500/buildkit-smoke:builder-test}"
BUILDKIT_CONTAINER="buildx_buildkit_${BUILDER_NAME}0"

if ! command -v docker >/dev/null 2>&1; then
	echo "[FAIL] docker is required"
	exit 2
fi

if ! docker buildx version >/dev/null 2>&1; then
	echo "[FAIL] docker buildx is required"
	exit 2
fi

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
	echo "[FAIL] registry CA cert not found: $REGISTRY_CA_CERT_PATH"
	exit 2
fi

tmp_dir="$(mktemp -d)"
smoke_cert_dir=""
cleanup() {
	rm -rf "$tmp_dir"
	[[ -z "$smoke_cert_dir" ]] || rm -rf "$smoke_cert_dir"
}
trap cleanup EXIT

cat >"$tmp_dir/Dockerfile" <<'EOF'
FROM scratch
LABEL org.opencontainers.image.title="threadforge-builder-smoke"
EOF

cat >"$tmp_dir/buildkitd.toml" <<EOF
[registry."registry.threadforge.local:30500"]
	ca = ["$REGISTRY_CA_CERT_PATH"]
EOF

docker buildx rm "$BUILDER_NAME" >/dev/null 2>&1 || true
docker buildx create --name "$BUILDER_NAME" --driver docker-container --driver-opt network=host --config "$tmp_dir/buildkitd.toml" --use >/dev/null
docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "$BUILDKIT_CONTAINER"; then
	docker exec "$BUILDKIT_CONTAINER" sh -lc 'mkdir -p /usr/local/share/ca-certificates'
	docker cp "$REGISTRY_CA_CERT_PATH" "$BUILDKIT_CONTAINER:/usr/local/share/ca-certificates/threadforge-ingress-ca.crt"
	docker exec "$BUILDKIT_CONTAINER" sh -lc 'update-ca-certificates >/dev/null 2>&1 || true'
	docker restart "$BUILDKIT_CONTAINER" >/dev/null
	docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null
fi

docker buildx build \
	--builder "$BUILDER_NAME" \
	--platform linux/arm64 \
	--push \
	-t "$SMOKE_IMAGE" \
	"$tmp_dir" >/dev/null

smoke_cert_dir="$(mktemp -d)"
cp "$REGISTRY_CA_CERT_PATH" "$smoke_cert_dir/ca.crt"
smoke_arch="$(skopeo inspect --tls-verify=true --cert-dir "$smoke_cert_dir" --format '{{.Architecture}}' "docker://${SMOKE_IMAGE}")"
if [[ "$smoke_arch" != "arm64" ]]; then
	echo "[FAIL] builder smoke image resolved to unexpected architecture: ${smoke_arch}"
	exit 2
fi

echo "[PASS] buildx builder '$BUILDER_NAME' is reproducibly configured for linux/arm64 pushes"
