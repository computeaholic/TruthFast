#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIND_CONFIG_PATH="${KIND_CONFIG_PATH:-$REPO_ROOT/platform/build/kind/kind-config.yaml}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-threadforge}"
COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
ALLOWED_IMAGE_PREFIX="${ALLOWED_IMAGE_PREFIX:-registry.threadforge.local:30500/}"
CONTROL_PLANE_NAME="kind-${KIND_CLUSTER_NAME}-control-plane"
ALT_CONTROL_PLANE_NAME="${KIND_CLUSTER_NAME}-control-plane"

if [ ! -f "$KIND_CONFIG_PATH" ]; then
	echo "[FAIL] kind config missing: $KIND_CONFIG_PATH"
	exit 10
fi

if [ ! -f "$COSIGN_PUBLIC_KEY_PATH" ]; then
	echo "[FAIL] cosign public key missing: $COSIGN_PUBLIC_KEY_PATH"
	exit 10
fi

if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
	echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
	exit 10
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "[FAIL] docker not found in PATH"
	exit 10
fi

if ! command -v cosign >/dev/null 2>&1; then
	echo "[FAIL] cosign not found in PATH"
	exit 10
fi

configured_image="$(awk '/^[[:space:]]*image:[[:space:]]*/ {print $2; exit}' "$KIND_CONFIG_PATH")"
if [ -z "$configured_image" ]; then
	echo "[FAIL] kind config missing node image"
	exit 2
fi

if [[ ! "$configured_image" =~ ^${ALLOWED_IMAGE_PREFIX//./\.}.+@sha256:[0-9a-f]{64}$ ]]; then
	echo "[FAIL] kind node image is not internal and digest pinned: $configured_image"
	exit 2
fi

container_name=""
if docker ps --format '{{.Names}}' | grep -q "^${CONTROL_PLANE_NAME}$"; then
	container_name="$CONTROL_PLANE_NAME"
elif docker ps --format '{{.Names}}' | grep -q "^${ALT_CONTROL_PLANE_NAME}$"; then
	container_name="$ALT_CONTROL_PLANE_NAME"
else
	echo "[FAIL] kind control-plane container not found"
	exit 2
fi

running_image="$(docker inspect -f '{{.Config.Image}}' "$container_name")"
if [ "$running_image" != "$configured_image" ]; then
	echo "[FAIL] kind control-plane image mismatch: $running_image != $configured_image"
	exit 2
fi

export SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH"
if ! cosign verify --key "$COSIGN_PUBLIC_KEY_PATH" --rekor-url https://rekor.sigstore.dev "$configured_image" >/dev/null 2>&1; then
	echo "[FAIL] kind node image is unsigned or signature verification failed: $configured_image"
	exit 2
fi

echo "[PASS] kind node image is internal, digest pinned, and signed"
