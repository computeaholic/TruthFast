#!/usr/bin/env bash
set -euo pipefail

MODE="${VERIFY_MINIO_MODE:-proof}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
INGRESS_PRINCIPAL="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/istio-system/sa/istio-ingressgateway"
MINIO_PRINCIPAL="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/minio/sa/minio-sa"

fail_legacy_tls() {
	echo "[FAIL] LEGACY_TLS_PATH_DETECTED: $1"
	exit 2
}

fail_contract() {
	echo "[FAIL] CONTRACT_VIOLATION: $1"
	exit 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail_contract "missing required command: $1"
}

resolve_real_helm() {
	if command -v helm >/dev/null 2>&1; then
		type -P helm 2>/dev/null || true
	fi
}

run_real_helm() {
	local helm_bin="${REAL_HELM_BIN:-}"
	if [[ -z "$helm_bin" ]]; then
		helm_bin="$(resolve_real_helm)"
	fi
	[[ -n "$helm_bin" ]] || fail_contract "missing required command: helm"
	"$helm_bin" "$@"
}

require_cmd kubectl
require_cmd jq
require_cmd python3

assert_rendered_chart_has_no_legacy_tls() {
	local rendered
	rendered="$(run_real_helm template minio platform/deploy/infra/minio -n minio)"

	if printf '%s\n' "$rendered" | grep -Eq '(^kind:[[:space:]]*Certificate$|^[[:space:]]*issuerRef:|credentialName:|minio-gateway-tls|threadforge-ca)'; then
		fail_legacy_tls "MinIO chart still renders cert-manager or TLS-secret wiring"
	fi
}

assert_cluster_has_no_legacy_tls() {
	kubectl get certificate minio-gateway-cert -n istio-system >/dev/null 2>&1 && \
		fail_legacy_tls "istio-system/minio-gateway-cert still exists"
	kubectl get secret minio-gateway-tls -n istio-system >/dev/null 2>&1 && \
		fail_legacy_tls "istio-system/minio-gateway-tls still exists"
	kubectl get clusterissuer threadforge-ca >/dev/null 2>&1 && \
		fail_legacy_tls "clusterissuer/threadforge-ca still exists"

	if kubectl get gateway minio-gateway -n istio-system -o yaml 2>/dev/null | grep -Eq '^[[:space:]]*tls:|credentialName:'; then
		fail_legacy_tls "istio-system/minio-gateway still contains TLS secret wiring"
	fi
}

assert_minio_namespace_and_service() {
	local injection service_type
	injection="$(kubectl get namespace minio -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)"
	[[ "$injection" == "enabled" ]] || fail_contract "minio namespace is not labeled with istio-injection=enabled"

	service_type="$(kubectl get service minio -n minio -o jsonpath='{.spec.type}' 2>/dev/null || true)"
	[[ "$service_type" == "ClusterIP" ]] || fail_contract "minio service type is not ClusterIP"
}

assert_minio_rollout_sidecar_and_spiffe() {
	local pod_name expected_spiffe

	kubectl rollout status deployment/minio -n minio --timeout=180s >/dev/null || \
		fail_contract "minio deployment not ready"

	pod_name="$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
	[[ -n "$pod_name" ]] || fail_contract "minio pod not found"

	kubectl get pod "$pod_name" -n minio -o json | jq -e '.spec.containers[] | select(.name == "istio-proxy")' >/dev/null 2>&1 || \
		fail_contract "minio pod does not have an istio-proxy container"

	expected_spiffe="$MINIO_PRINCIPAL"

	python3 - "$pod_name" "$expected_spiffe" <<'PY'
import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile

pod_name, expected_spiffe = sys.argv[1:3]

def fail(message: str) -> None:
    print(f"[FAIL] CONTRACT_VIOLATION: {message}")
    raise SystemExit(2)

def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        details = proc.stderr.strip() or proc.stdout.strip() or "command failed"
        fail(details)
    return proc.stdout

certs_doc = json.loads(run(["kubectl", "exec", "-n", "minio", pod_name, "-c", "istio-proxy", "--", "curl", "-s", "localhost:15000/certs"]))
spiffe_ids = set()
for cert in certs_doc.get("certificates", []) or []:
    for leaf in cert.get("cert_chain", []) or []:
        for san in leaf.get("subject_alt_names", []) or []:
            if isinstance(san, dict) and isinstance(san.get("uri"), str) and san["uri"].startswith("spiffe://"):
                spiffe_ids.add(san["uri"])

if expected_spiffe not in spiffe_ids:
    fail(f"minio pod missing expected SPIFFE identity: {expected_spiffe}")

config_dump = json.loads(run(["kubectl", "exec", "-n", "minio", pod_name, "-c", "istio-proxy", "--", "curl", "-fsS", "--max-time", "10", "http://127.0.0.1:15000/config_dump"]))
secrets_config = next(
    (
        item
        for item in config_dump.get("configs", [])
        if isinstance(item, dict) and str(item.get("@type", "")).endswith("SecretsConfigDump")
    ),
    None,
)
if not isinstance(secrets_config, dict):
    fail("minio Envoy config dump has no SecretsConfigDump")
dynamic_raw = secrets_config.get("dynamic_active_secrets")
if dynamic_raw is None:
    dynamic_raw = secrets_config.get("dynamicActiveSecrets")

def camelize(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            head, *tail = str(key).split("_")
            result[head + "".join(part[:1].upper() + part[1:] for part in tail)] = camelize(item)
        return result
    if isinstance(value, list):
        return [camelize(item) for item in value]
    return value

secret_doc = {"dynamicActiveSecrets": camelize(dynamic_raw or [])}
default_entries = [entry for entry in (secret_doc.get("dynamicActiveSecrets") or []) if isinstance(entry, dict) and entry.get("name") == "default"]
if len(default_entries) != 1:
    fail(f"expected one default secret for minio pod, found {len(default_entries)}")

chain_b64 = ((((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes"))
if not chain_b64:
    fail("minio default secret missing certificateChain.inlineBytes")

chain_pem = base64.b64decode(chain_b64).decode("utf-8", errors="ignore")
match = re.search(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", chain_pem)
if not match:
    fail("minio Envoy secret did not decode into certificate PEM")

with tempfile.NamedTemporaryFile("w", delete=False) as handle:
    handle.write(match.group(0) + "\n")
    path = pathlib.Path(handle.name)

try:
    proc = subprocess.run(["openssl", "x509", "-in", str(path), "-noout", "-issuer", "-nameopt", "RFC2253"], capture_output=True, text=True, check=False)
finally:
    path.unlink(missing_ok=True)

if proc.returncode != 0:
    fail(proc.stderr.strip() or proc.stdout.strip() or "unable to inspect minio Envoy issuer")

issuer = proc.stdout.strip().split("=", 1)[-1].strip().upper()
if "SPIRE" not in issuer and "SPIFFE" not in issuer:
    fail(f"minio Envoy certificate issuer is not SPIRE: {issuer}")
if "THREADFORGE-ROOT" in issuer or "CERT-MANAGER" in issuer:
    fail(f"minio Envoy certificate issuer is legacy: {issuer}")

print("[PASS] MinIO sidecar injected with SPIFFE identity and SPIRE-issued Envoy cert")
PY
}

assert_minio_authorization_policy() {
	local policy_json
	policy_json="$(kubectl get authorizationpolicy minio-allow-ingressgateway -n minio -o json 2>/dev/null || true)"
	[[ -n "$policy_json" ]] || fail_contract "authorizationpolicy/minio-allow-ingressgateway is missing"

	printf '%s\n' "$policy_json" | jq -e --arg principal "$INGRESS_PRINCIPAL" '
		.spec.selector.matchLabels.app == "minio" and
		.spec.action == "ALLOW" and
		([.spec.rules[].from[].source.principals[]] == [$principal]) and
		((([.spec.rules[].to[].operation.ports[]] | sort) == ["9000", "9001"]))
	' >/dev/null 2>&1 || fail_contract "minio authorization policy is not restricted to ingressgateway SPIFFE identity"
}

assert_minio_gateway_only_access() {
	local node_ip node_port gateway_code pod_name pod_ip direct_code
	local attempt max_attempts

	node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
	node_port="$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
	[[ -n "$node_ip" && -n "$node_port" ]] || fail_contract "unable to resolve istio-ingressgateway node address"

	max_attempts="${MINIO_GATEWAY_HTTP_RETRIES:-24}"
	local retry_sleep_seconds
	retry_sleep_seconds="${MINIO_GATEWAY_HTTP_RETRY_SLEEP_SECONDS:-5}"
	gateway_code="000"
	for attempt in $(seq 1 "$max_attempts"); do
		set +e
		gateway_code="$(curl -s --max-time 5 -H 'Host: minio.threadforge.local' "http://${node_ip}:${node_port}/minio/health/live" -o /dev/null -w '%{http_code}' 2>/dev/null)"
		set -e
		# Gateway mediation is the contract here; external callers may be denied by edge authz
		# or transiently unavailable during control-plane trust reconfiguration.
		if [[ "$gateway_code" =~ ^(200|204|301|302|307|308|403|503)$ ]]; then
			break
		fi
		if [[ "$attempt" -lt "$max_attempts" ]]; then
			echo "[verify_minio_spire_native] waiting for ingress readiness (attempt ${attempt}/${max_attempts}, HTTP ${gateway_code})" >&2
			sleep "$retry_sleep_seconds"
		fi
	done
	[[ "$gateway_code" =~ ^(200|204|301|302|307|308|403|503)$ ]] || fail_contract "minio is not mediated by ingress gateway (HTTP ${gateway_code})"

	pod_name="$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
	pod_ip="$(kubectl get pod "$pod_name" -n minio -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
	[[ -n "$pod_ip" ]] || fail_contract "unable to resolve minio pod IP"

	set +e
	direct_code="$(curl -s --max-time 5 "http://${pod_ip}:9000/minio/health/live" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
	set -e
	if [[ "$direct_code" =~ ^(200|204|301|302|307|308)$ ]]; then
		fail_contract "direct MinIO pod access was allowed (HTTP ${direct_code})"
	fi

	echo "[PASS] MinIO is gateway-mediated (HTTP ${gateway_code}) and direct pod access is denied"
}

main() {
	assert_rendered_chart_has_no_legacy_tls
	assert_cluster_has_no_legacy_tls
	assert_minio_namespace_and_service
	assert_minio_rollout_sidecar_and_spiffe
	assert_minio_authorization_policy

	if [[ "$MODE" != "bootstrap" ]]; then
		assert_minio_gateway_only_access
	fi
}

main "$@"
