#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAB_K8S_DIR="${REPO_ROOT}/platform/labs/agent-containment/k8s"
THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
RESOLVED_DEPLOYMENTS="$(mktemp)"
cleanup_resolved_deployments() {
	rm -f "${RESOLVED_DEPLOYMENTS}"
}
trap cleanup_resolved_deployments EXIT

run_required_validation() {
	local script_path="$1"
	local pass_marker="$2"
	local output
	if ! output="$(bash "${script_path}" 2>&1)"; then
		printf '%s\n' "${output}"
		return 1
	fi
	printf '%s\n' "${output}"
	if ! grep -Fq "${pass_marker}" <<<"${output}"; then
		echo "[FAIL] required validation did not prove: ${pass_marker}"
		return 2
	fi
}

ensure_agents_lab_runtime_credentials() {
	local registry_user="${THREADFORGE_REGISTRY_USER:-threadforge}"
	local registry_password="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
	local root_cert_tmp root_cert_secret sa

	echo "[STEP 6.2] Creating agents-lab registry credentials"
	kubectl -n agents-lab create secret docker-registry registry-credentials \
		--docker-server="${THREADFORGE_REGISTRY}" \
		--docker-username="${registry_user}" \
		--docker-password="${registry_password}" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null

	root_cert_tmp="$(mktemp)"
	kubectl -n agents-lab get configmap istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' >"${root_cert_tmp}"
	for sa in research-agent writer-agent attacker-agent rogue-agent; do
		echo "[STEP 6.3] Creating agents-lab root cert secret for ${sa}"
		kubectl -n agents-lab create secret generic "istio.${sa}" \
			--from-file=root-cert.pem="${root_cert_tmp}" \
			--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	done
	rm -f "${root_cert_tmp}"
}

echo "[STEP 0] Validate cluster preflight"
run_required_validation \
	"${REPO_ROOT}/scripts/advisory/validate_cluster.sh" \
	"[PASS] Cluster preflight checks passed"

echo "[STEP 1] Validate canonical SPIRE"
run_required_validation \
	"${REPO_ROOT}/scripts/advisory/validate_spire.sh" \
	"[PASS] SPIRE control plane healthy"

echo "[STEP 2] Validate canonical Istio"
run_required_validation \
	"${REPO_ROOT}/scripts/advisory/validate_istio.sh" \
	"[PASS] Istio control plane healthy"

istio_webhook_bundle_is_expired() {
	local tmp_cert tmp_json webhook_names webhook_name bundle_b64
	tmp_cert="$(mktemp)"
	tmp_json="$(mktemp)"
	webhook_names=""

	if kubectl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null 2>&1; then
		webhook_names="$(kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o name 2>/dev/null || true)"
	fi
	if kubectl get validatingwebhookconfiguration istio-validator-istio-system >/dev/null 2>&1; then
		webhook_names="${webhook_names}
$(kubectl get validatingwebhookconfiguration istio-validator-istio-system -o name 2>/dev/null || true)"
	fi
	if kubectl get validatingwebhookconfiguration istiod-default-validator >/dev/null 2>&1; then
		webhook_names="${webhook_names}
$(kubectl get validatingwebhookconfiguration istiod-default-validator -o name 2>/dev/null || true)"
	fi

	for webhook_name in ${webhook_names}; do
		[[ -n "${webhook_name}" ]] || continue
		kubectl get "${webhook_name}" -o json >"${tmp_json}" 2>/dev/null || continue
		while IFS= read -r bundle_b64; do
			[[ -n "${bundle_b64}" ]] || continue
			if ! printf '%s' "${bundle_b64}" | base64 -d >"${tmp_cert}" 2>/dev/null; then
				rm -f "${tmp_cert}" "${tmp_json}"
				return 0
			fi
			if ! openssl x509 -in "${tmp_cert}" -noout -checkend 0 >/dev/null 2>&1; then
				rm -f "${tmp_cert}" "${tmp_json}"
				return 0
			fi
		done < <(jq -r '.webhooks[]?.clientConfig.caBundle // empty' "${tmp_json}" | sed '/^$/d')
	done

	rm -f "${tmp_cert}" "${tmp_json}"
	return 1
}

istiod_serving_cert_is_expired() {
	local tmp_cert bundle_b64
	tmp_cert="$(mktemp)"
	bundle_b64="$(kubectl -n istio-system get secret istiod-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
	if [[ -z "${bundle_b64}" ]]; then
		rm -f "${tmp_cert}"
		return 0
	fi
	if ! printf '%s' "${bundle_b64}" | base64 -d >"${tmp_cert}" 2>/dev/null; then
		rm -f "${tmp_cert}"
		return 0
	fi
	if ! openssl x509 -in "${tmp_cert}" -noout -checkend 0 >/dev/null 2>&1; then
		rm -f "${tmp_cert}"
		return 0
	fi
	rm -f "${tmp_cert}"
	return 1
}

if istio_webhook_bundle_is_expired || istiod_serving_cert_is_expired; then
	echo "[STEP 2.1] Refreshing SPIRE->Istio CA path for expired Istio admission certs"
	bash "${REPO_ROOT}/scripts/verify/refresh_spire_istio_ca_path.sh"
fi

echo "[STEP 3] Validate control plane"
bash "${REPO_ROOT}/scripts/advisory/validate_istio.sh"

echo "[STEP 4] Validate SPIRE"
run_required_validation \
	"${REPO_ROOT}/scripts/advisory/validate_spire.sh" \
	"[PASS] SPIRE control plane healthy"

echo "[STEP 5] Validate SPIRE"
bash "${REPO_ROOT}/scripts/advisory/validate_spire.sh"

echo "[STEP 6] Prepare namespace"
bash "${REPO_ROOT}/scripts/install/prepare_namespace.sh"
ensure_agents_lab_runtime_credentials

echo "[STEP 6.1] Apply network lockdown"
kubectl apply -f "${LAB_K8S_DIR}/network-deny-all.yaml"
kubectl apply -f "${LAB_K8S_DIR}/network-allow-istio.yaml"

echo "[STEP 7] Apply mTLS"
kubectl apply -f "${LAB_K8S_DIR}/peerauthentication-strict.yaml"

echo "[STEP 8] Deploy workloads"
AGENTS_RESOLVED_DEPLOYMENTS="${RESOLVED_DEPLOYMENTS}" \
	bash "${REPO_ROOT}/scripts/install/prepare_agents_lab_images.sh"
kubectl apply -f "${LAB_K8S_DIR}/serviceaccounts.yaml"
for app in research-agent writer-agent attacker-agent rogue-agent; do
	kubectl apply -f "${RESOLVED_DEPLOYMENTS}" -l "app=${app}"
	kubectl rollout status "deployment/${app}" -n agents-lab --timeout=180s
done
kubectl apply -f "${LAB_K8S_DIR}/services.yaml"

echo "[STEP 8.1] Wait for workloads to be ready"
kubectl rollout status deployment/research-agent -n agents-lab --timeout=180s
kubectl rollout status deployment/writer-agent -n agents-lab --timeout=180s
kubectl rollout status deployment/attacker-agent -n agents-lab --timeout=180s
kubectl rollout status deployment/rogue-agent -n agents-lab --timeout=180s

echo "[STEP 8.2] Verify sidecar is present on every workload pod"
for APP in research-agent writer-agent attacker-agent rogue-agent; do
	POD_NAME="$(kubectl get pod -n agents-lab -l app="${APP}" -o jsonpath='{.items[0].metadata.name}')"
	if [[ -z "${POD_NAME}" ]]; then
		echo "[FAIL] Missing pod for ${APP}"
		exit 2
	fi
	CONTAINER_NAMES="$(kubectl get pod -n agents-lab "${POD_NAME}" -o jsonpath='{.spec.containers[*].name}')"
	if [[ " ${CONTAINER_NAMES} " != *" istio-proxy "* ]]; then
		echo "[FAIL] Pod ${POD_NAME} is missing istio-proxy"
		exit 2
	fi
done

echo "[STEP 8.3] Verify SPIFFE identity material is present"
for APP in research-agent writer-agent attacker-agent rogue-agent; do
	SPIFFE_ID="$(kubectl exec deploy/${APP} -n agents-lab -- printenv SPIFFE_ID 2>/dev/null || true)"
	if [[ -z "${SPIFFE_ID}" ]] || [[ ! "${SPIFFE_ID}" =~ ^spiffe://.*/ns/agents-lab/sa/${APP}$ ]]; then
		echo "[FAIL] SPIFFE identity missing for ${APP}"
		exit 2
	fi
done

echo "[STEP 8.4] Verify runtime image model mapping"
LAB_RESOLVED="${RESOLVED_DEPLOYMENTS}" \
	bash "${REPO_ROOT}/scripts/advisory/verify_runtime_image_model.sh"

echo "[STEP 8.5] Reconcile runtime image drift projection"
bash "${REPO_ROOT}/scripts/debug/reconcile_runtime_drift.sh"

echo "[STEP 9] Apply policies"
kubectl delete authorizationpolicy allow-research-to-writer -n agents-lab --ignore-not-found
kubectl apply -f "${LAB_K8S_DIR}/writer-allow.yaml"
kubectl apply -f "${LAB_K8S_DIR}/policies.yaml"

echo "[VERIFY] Checking STRICT mTLS via API"
MTLS_MODE="$(kubectl get peerauthentication -n agents-lab -o jsonpath='{.items[*].spec.mtls.mode}')"
echo "[VERIFY] mTLS mode: ${MTLS_MODE}"
if [[ "${MTLS_MODE}" != "STRICT" ]]; then
	echo "[FAIL] Expected STRICT mTLS mode"
	exit 2
fi

echo "[VERIFY] Checking sidecar injection via API"
POD_CONTAINERS="$(kubectl get pod -n agents-lab -o jsonpath='{.items[*].spec.containers[*].name}')"
if [[ "${POD_CONTAINERS}" != *"istio-proxy"* ]]; then
	echo "[FAIL] istio-proxy sidecar missing from agents-lab pods"
	exit 2
fi

echo "[VERIFY] Checking no plaintext service path"
PLAINTEXT_EXEC_RC=0
PLAINTEXT_STATUS="$(kubectl exec deploy/research-agent -n agents-lab -- \
	sh -c 'curl -sS --max-time 10 -o /dev/null -w "%{http_code}" http://writer-agent:8080' 2>/dev/null)" || PLAINTEXT_EXEC_RC=$?
echo "[VERIFY] plaintext probe status: ${PLAINTEXT_STATUS}"
if [[ ! "${PLAINTEXT_STATUS}" =~ ^[0-9]{3}$ ]]; then
	echo "[FAIL] Plaintext probe did not produce an HTTP status (kubectl rc=${PLAINTEXT_EXEC_RC})"
	exit 2
fi
if [[ "${PLAINTEXT_STATUS}" == "200" ]]; then
	echo "[FAIL] Plaintext service path succeeded"
	exit 2
fi

echo "[VERIFY] Policies:"
kubectl get authorizationpolicy -n agents-lab

echo "[VERIFY] PeerAuthentication:"
kubectl get peerauthentication -n agents-lab

echo "[STEP 10] Enforce observability truth gate"
if kubectl get ns observability >/dev/null 2>&1; then
	bash "${REPO_ROOT}/scripts/advisory/observability/observability_check.sh"
else
	echo "[STEP 9] observability namespace absent; skipping observability truth gate"
fi

echo "[DONE] Lab deployed with verified control plane"
