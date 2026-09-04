#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
CERT_MANAGER_CONTROLLER_IMAGE="${CERT_MANAGER_CONTROLLER_IMAGE:-registry.threadforge.local:30500/cert-manager/controller@sha256:6bf0fd34e1d5b58e31bfdc640d5d284e528685b19f20df6c0fb6f13867603bba}"
CERT_MANAGER_CAINJECTOR_IMAGE="${CERT_MANAGER_CAINJECTOR_IMAGE:-registry.threadforge.local:30500/cert-manager/cainjector@sha256:6381b508a274d56f0ed3ac6af76faf12e3e5a2e0028d33a13039e364c45c93ff}"
CERT_MANAGER_WEBHOOK_IMAGE="${CERT_MANAGER_WEBHOOK_IMAGE:-registry.threadforge.local:30500/cert-manager/webhook@sha256:7f16d397b8b48c5133d9f2859fb2dea30f0f297eb04c517bbfc06f5d207b3cf0}"
CERT_MANAGER_STARTUPAPICHECK_IMAGE="${CERT_MANAGER_STARTUPAPICHECK_IMAGE:-registry.threadforge.local:30500/cert-manager/startupapicheck@sha256:d313d9b8a846c163e52eebe68fd5e7da2457fddda2f144848de17b6fcd6e14f4}"
ISTIO_PILOT_IMAGE="${ISTIO_PILOT_IMAGE:-registry.threadforge.local:30500/istio/pilot@sha256:32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f}"
SPIRE_SERVER_IMAGE="${SPIRE_SERVER_IMAGE:-registry.threadforge.local:30500/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8}"
SPIRE_AGENT_IMAGE="${SPIRE_AGENT_IMAGE:-registry.threadforge.local:30500/spiffe/spire-agent@sha256:0d3cebdf4e033edaa67ef1b4197696f853bb76f8970e25010237c7e3a7c98531}"
REGISTRY_CERT_DIR=""

if ! command -v skopeo >/dev/null 2>&1; then
	echo "[FAIL] skopeo is required"
	exit 2
fi

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
	echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
	exit 2
fi

REGISTRY_CERT_DIR="$(mktemp -d)"
cleanup_registry_cert_dir() {
	rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup_registry_cert_dir EXIT
cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"

classify_skopeo_error() {
	local output="$1"
	local lowered
	lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

	if [[ "$lowered" == *"x509"* ]] || [[ "$lowered" == *"certificate"* ]] || [[ "$lowered" == *"tls"* ]] || [[ "$lowered" == *"ssl"* ]]; then
		printf '%s' "REGISTRY_TLS_FAILURE"
		return
	fi
	if [[ "$lowered" == *"unauthorized"* ]] || [[ "$lowered" == *"authentication required"* ]] || [[ "$lowered" == *"denied"* ]]; then
		printf '%s' "REGISTRY_AUTH_FAILURE"
		return
	fi
	if [[ "$lowered" == *"manifest unknown"* ]] || [[ "$lowered" == *"not found"* ]] || [[ "$lowered" == *"name unknown"* ]]; then
		printf '%s' "MISSING_IMAGE"
		return
	fi

	printf '%s' "REGISTRY_PROBE_FAILURE"
}

required_images=(
	"$CERT_MANAGER_CONTROLLER_IMAGE"
	"$CERT_MANAGER_CAINJECTOR_IMAGE"
	"$CERT_MANAGER_WEBHOOK_IMAGE"
	"$CERT_MANAGER_STARTUPAPICHECK_IMAGE"
	"$ISTIO_PILOT_IMAGE"
	"$SPIRE_SERVER_IMAGE"
	"$SPIRE_AGENT_IMAGE"
)

missing=0
for image_ref in "${required_images[@]}"; do
	[[ -n "$image_ref" ]] || continue
	if [[ ! "$image_ref" =~ ^registry\.threadforge\.local:30500/.+@sha256:[0-9a-f]{64}$ ]]; then
		echo "[FAIL] MISSING_IMAGE: ${image_ref}"
		missing=1
		continue
	fi
	set +e
	skopeo_output="$(skopeo inspect --creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${image_ref}" 2>&1)"
	skopeo_rc=$?
	set -e
	resolved_digest="$(printf '%s' "$skopeo_output" | tr -d '\r' | tr -d '\n')"
	if [[ "$skopeo_rc" -ne 0 ]]; then
		kind="$(classify_skopeo_error "$skopeo_output")"
		echo "[FAIL] ${kind}: ${image_ref}"
		missing=1
		continue
	fi
	if [[ "$resolved_digest" != "${image_ref##*@}" ]]; then
		echo "[FAIL] MISSING_IMAGE: ${image_ref}"
		missing=1
	fi
done

if [[ "$missing" -ne 0 ]]; then
	exit 11
fi

echo "[PASS] required registry images are present and digest pinned"
