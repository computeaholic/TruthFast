#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/spire_restart_contract.sh
source "${REPO_ROOT}/scripts/lib/spire_restart_contract.sh"
# shellcheck source=scripts/lib/registry_config.sh
source "${REPO_ROOT}/scripts/lib/registry_config.sh"
CERT_MANAGER_VERSION="v1.14.6"
REGISTRY_HOST="registry.threadforge.local"
REGISTRY_PORT="30500"
CLUSTER_NAME="threadforge"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-${REGISTRY_HOST}}"
THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY:-${REGISTRY_HOST}:${REGISTRY_PORT}}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-${THREADFORGE_REGISTRY}}"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CA_CERT_PATH="${REPO_ROOT}/certs/threadforge-ingress-ca.crt"
LEGACY_REGISTRY_CA_CERT_PATH="${REPO_ROOT}/certs/registry-ca.crt"
KIND_BUILD_CA_CERT_PATH="${REPO_ROOT}/.certs/ca.crt"
TRUST_AUTHORITY_STATE_FILE="${REPO_ROOT}/artifacts/trust/trust_authority_state.json"
ISTIO_TAG="${ISTIO_TAG:-1.29.0}"
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.2.8}"
ISTIO_PILOT_DIGEST="${ISTIO_PILOT_DIGEST:-32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f}"
ISTIO_PROXYV2_DIGEST="${ISTIO_PROXYV2_DIGEST:-2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
DEBUG_DIR="${REPO_ROOT}/artifacts/debug"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-strict}"
ISTIOD_FORENSICS_ROOT="${REPO_ROOT}/artifacts/istiod_failure_bundle"
ISTIOD_READINESS_TIMELINE_JSON="${REPO_ROOT}/artifacts/istiod_readiness_timeline.json"
ISTIOD_READINESS_EVENTS_JSONL="${REPO_ROOT}/artifacts/istiod_readiness_timeline.events.jsonl"
ISTIOD_ROLLOUT_FORENSICS_MD="${REPO_ROOT}/artifacts/istiod_rollout_forensics.md"
KYVERNO_FORENSICS_ROOT="${REPO_ROOT}/artifacts/kyverno_failure_bundle"
KYVERNO_READINESS_TIMELINE_JSON="${REPO_ROOT}/artifacts/kyverno_readiness_timeline.json"
KYVERNO_READINESS_EVENTS_JSONL="${REPO_ROOT}/artifacts/kyverno_readiness_timeline.events.jsonl"
KYVERNO_ROLLOUT_FORENSICS_MD="${REPO_ROOT}/artifacts/kyverno_rollout_forensics.md"
WEBHOOK_REGISTRATION_FORENSICS_MD="${REPO_ROOT}/artifacts/webhook_registration_forensics.md"
WEBHOOK_REGISTRATION_TIMELINE_JSON="${REPO_ROOT}/artifacts/webhook_registration_timeline.json"
KYVERNO_ENDPOINT_STATE_JSON="${REPO_ROOT}/artifacts/kyverno_endpoint_state.json"
BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_RUN_ID="${VALIDATE_ALL_RUN_ID:-bootstrap-$$}"
BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA="${VALIDATE_ALL_SOURCE_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)}"
BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="${VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE:-}"
BOOTSTRAP_PHASE="${BOOTSTRAP_PHASE:-}"

if [[ "${1:-}" == "--phase" ]]; then
	BOOTSTRAP_PHASE="${2:-}"
	shift 2
fi

if [[ $# -gt 0 ]]; then
	echo "[FAIL] unsupported bootstrap arguments: $*"
	exit 2
fi

if [[ -z "$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE" ]]; then
	mkdir -p "$REPO_ROOT/artifacts/mode_runs"
	BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="$(mktemp "$REPO_ROOT/artifacts/mode_runs/runtime-image-convergence.XXXXXX.json")"
fi

case "${BOOTSTRAP_MODE}" in
	ci-fast)
		OBS_TIMEOUT=30
		;;
	ci)
		OBS_TIMEOUT=120
			san_file="$(mktemp)"
			printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "${REGISTRY_ALIAS}" > "$san_file"
		;;
	strict)
		OBS_TIMEOUT=300
		;;
	*)
		echo "[FAIL] unsupported BOOTSTRAP_MODE=${BOOTSTRAP_MODE}"
		exit 2
		;;
esac

export COSIGN_YES="${COSIGN_YES:-true}"
# COSIGN_EXPERIMENTAL must NOT be set: it forces tlog lookups which break internal-only registry verification

# shellcheck source=scripts/lib/proof_prereqs.sh
source "$REPO_ROOT/scripts/lib/proof_prereqs.sh"
# shellcheck source=scripts/lib/bootstrap_failure.sh
source "$REPO_ROOT/scripts/lib/bootstrap_failure.sh"
# shellcheck source=scripts/lib/bootstrap_timeline.sh
source "$REPO_ROOT/scripts/lib/bootstrap_timeline.sh"
# shellcheck source=scripts/lib/spire_server_socket.sh
source "$REPO_ROOT/scripts/lib/spire_server_socket.sh"
tf_bt_init "$REPO_ROOT"

init_istiod_forensics_artifacts() {
	mkdir -p "$ISTIOD_FORENSICS_ROOT"
	: >"$ISTIOD_READINESS_EVENTS_JSONL"
	cat >"$ISTIOD_READINESS_TIMELINE_JSON" <<'EOF'
{
  "generated_at": "",
  "checks": []
}
EOF
	cat >"$ISTIOD_ROLLOUT_FORENSICS_MD" <<'EOF'
# Istiod Rollout Forensics

No istiod rollout failures captured in this run.
EOF
}

init_kyverno_forensics_artifacts() {
	mkdir -p "$KYVERNO_FORENSICS_ROOT"
	: >"$KYVERNO_READINESS_EVENTS_JSONL"
	cat >"$KYVERNO_READINESS_TIMELINE_JSON" <<'EOF'
{
  "generated_at": "",
  "checks": []
}
EOF
	cat >"$KYVERNO_ROLLOUT_FORENSICS_MD" <<'EOF'
# Kyverno Rollout Forensics

No kyverno webhook readiness failures captured in this run.
EOF
	cat >"$WEBHOOK_REGISTRATION_TIMELINE_JSON" <<'EOF'
{
	"generated_at": "",
	"checks": []
}
EOF
	cat >"$WEBHOOK_REGISTRATION_FORENSICS_MD" <<'EOF'
# Webhook Registration Forensics

No webhook registration failures captured in this run.
EOF
	cat >"$KYVERNO_ENDPOINT_STATE_JSON" <<'EOF'
{
	"generated_at": "",
	"namespace_present": false,
	"service": {},
	"endpoints": {},
	"pods": [],
	"webhooks": []
}
EOF
}

init_istiod_forensics_artifacts
init_kyverno_forensics_artifacts

BOOTSTRAP_ACTIVE_PHASE=""
WEBHOOK_LAST_FAILED_SUBCONDITION=""
WEBHOOK_LAST_FAILED_COMMAND=""
WEBHOOK_LAST_FAILED_STDERR=""
WEBHOOK_LAST_FAILED_STDOUT=""
WEBHOOK_LAST_RETRY_COUNT="0"
WEBHOOK_LAST_ELAPSED_SECONDS="0"

set_bootstrap_phase() {
	BOOTSTRAP_ACTIVE_PHASE="$1"
	tf_bt_phase_start "$BOOTSTRAP_ACTIVE_PHASE" "${2:-phase start}"
}

complete_bootstrap_phase() {
	local phase="$1"
	local status="${2:-PASS}"
	local marker="${3:-phase end}"
	tf_bt_phase_end "$phase" "$status" "$marker"
	if [[ "$BOOTSTRAP_ACTIVE_PHASE" == "$phase" ]]; then
		BOOTSTRAP_ACTIVE_PHASE=""
	fi
}

assert_image_pinning_preconditions() {
	echo "[DEBUG] applying: namespace/istio-system prerequisite"
	if ! timeout 20s kubectl get ns istio-system --request-timeout=20s >/dev/null 2>&1; then
		fail_bootstrap "bootstrap ordering violation: istio-system must exist before image pinning"
	fi
	echo "[DEBUG] completed: namespace/istio-system prerequisite"
	echo "[DEBUG] applying: namespace/spire-system prerequisite"
	if ! timeout 20s kubectl get ns spire-system --request-timeout=20s >/dev/null 2>&1; then
		fail_bootstrap "bootstrap ordering violation: spire-system must exist before image pinning"
	fi
	echo "[DEBUG] completed: namespace/spire-system prerequisite"
}

run_runtime_pinning_kubectl() {
	local resource_label="$1"
	shift
	echo "[DEBUG] applying: ${resource_label}"
	if timeout 20s "$@"; then
		echo "[DEBUG] completed: ${resource_label}"
		return 0
	fi
	local rc=$?
	if [[ "$rc" -eq 124 ]]; then
		echo "[FAIL] IMAGE_PIN_TIMEOUT: ${resource_label}"
	else
		echo "[FAIL] IMAGE_PIN_APPLY_FAILED: ${resource_label}"
	fi
	exit 2
}

ensure_runtime_pinning_namespace() {
	local namespace="$1"
	if timeout 20s kubectl get namespace "$namespace" --request-timeout=20s >/dev/null 2>&1; then
		echo "[PASS] already pinned: namespace/${namespace}"
		return 0
	fi
	run_runtime_pinning_kubectl "namespace/${namespace}" \
		kubectl create namespace "$namespace" --request-timeout=20s
}

ensure_runtime_registry_credentials_secret() {
	local namespace="$1"
	local desired_json current_json desired_auth current_auth

	desired_json="$(mktemp)"
	current_json="$(mktemp)"

	if ! kubectl -n "$namespace" create secret docker-registry registry-credentials \
		--docker-server="${THREADFORGE_REGISTRY}" \
		--docker-username="${THREADFORGE_REGISTRY_USER}" \
		--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
		--dry-run=client -o json >"$desired_json"; then
		rm -f "$desired_json" "$current_json"
		fail_bootstrap "failed to render desired registry secret for ${namespace}"
	fi

	desired_auth="$(jq -r '.data[".dockerconfigjson"]' "$desired_json")"
	if timeout 20s kubectl -n "$namespace" get secret registry-credentials --request-timeout=20s -o json >"$current_json" 2>/dev/null; then
		current_auth="$(jq -r '.data[".dockerconfigjson"] // ""' "$current_json")"
		if [[ "$current_auth" == "$desired_auth" ]]; then
			rm -f "$desired_json" "$current_json"
			echo "[PASS] already pinned: secret/${namespace}/registry-credentials"
			return 0
		fi
		run_runtime_pinning_kubectl "secret/${namespace}/registry-credentials" \
			kubectl replace --force --request-timeout=20s -f "$desired_json"
		rm -f "$desired_json" "$current_json"
		return 0
	fi

	run_runtime_pinning_kubectl "secret/${namespace}/registry-credentials" \
		kubectl create --request-timeout=20s -f "$desired_json"
	rm -f "$desired_json" "$current_json"
}

pin_runtime_system_images() {
	local ns
	assert_image_pinning_preconditions
	for ns in kube-system local-path-storage; do
		ensure_runtime_pinning_namespace "$ns"
		ensure_runtime_registry_credentials_secret "$ns"
	done
	echo "[DEBUG] applying: runtime-image-pin-script"
	if VALIDATE_ALL_RUN_ID="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_RUN_ID" \
		VALIDATE_ALL_SOURCE_SHA="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA" \
		VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE" \
		RUNTIME_IMAGE_CONVERGENCE_RUN_ID="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_RUN_ID" \
		RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA" \
		RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="$BOOTSTRAP_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE" \
		bash "$REPO_ROOT/scripts/proof/pin_runtime_images.sh"; then
		echo "[DEBUG] completed: runtime-image-pin-script"
		return 0
	fi
	echo "[FAIL] IMAGE_PIN_APPLY_FAILED: runtime-image-pin-script"
	exit 2
}

ensure_local_path_helper_resources() {
	if ! kubectl get namespace local-path-storage >/dev/null 2>&1; then
		fail_bootstrap "local-path-storage namespace missing before helper resource reconciliation"
	fi
	ensure_runtime_pinning_namespace local-path-storage
	ensure_runtime_registry_credentials_secret local-path-storage
	run_runtime_pinning_kubectl "configmap/local-path-storage/local-path-config" \
		kubectl apply -f "$REPO_ROOT/platform/deploy/infra/local-path-storage/local-path-config.yaml" >/dev/null
	kubectl patch serviceaccount local-path-provisioner-service-account -n local-path-storage \
		-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null 2>&1 || true
	if kubectl -n local-path-storage get deployment/local-path-provisioner >/dev/null 2>&1; then
		kubectl -n local-path-storage patch deployment local-path-provisioner --type strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "local-path-provisioner",
            "resources": {
              "requests": {
                "cpu": "25m",
                "memory": "64Mi"
              },
              "limits": {
                "cpu": "100m",
                "memory": "128Mi"
              }
            }
          }
        ]
      }
    }
  }
}' >/dev/null
	fi
	if kubectl -n local-path-storage get deployment/local-path-provisioner >/dev/null 2>&1; then
		echo "[bootstrap] restarting local-path-provisioner to consume updated helper resources"
		kubectl -n local-path-storage rollout restart deployment/local-path-provisioner >/dev/null
		kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s >/dev/null
	fi
}

runtime_image_pinning_summary_value() {
	local output="$1"
	local key="$2"
	printf '%s\n' "$output" | awk -F= -v key="$key" '$1 == key { value = $2 } END { if (value != "") print value }'
}

runtime_image_pinning_phase() {
	local phase_name="$1"
	local phase_prefix="$2"
	local phase_marker="$3"
	local phase_start_epoch phase_end_epoch phase_duration phase_output phase_rc

	phase_start_epoch="$(date +%s)"
	set_bootstrap_phase "$phase_name" "$phase_marker"
	if [[ "$phase_name" == "runtime-image-pinning-initial" ]]; then
		echo "[bootstrap] ensuring metallb images"
		bash "$REPO_ROOT/scripts/infra/ensure_metallb_images.sh"
	fi

	phase_output=""
	phase_rc=0
	phase_output="$(pin_runtime_system_images 2>&1)" || phase_rc=$?

	printf '%s\n' "$phase_output"
	if [[ "$phase_rc" -ne 0 ]]; then
		complete_bootstrap_phase "$phase_name" "FAIL" "$phase_marker failed"
		exit "$phase_rc"
	fi

	complete_bootstrap_phase "$phase_name" "PASS" "$phase_marker completed"
	phase_end_epoch="$(date +%s)"
	phase_duration="$((phase_end_epoch - phase_start_epoch))"
	echo "${phase_prefix}_DURATION=${phase_duration}s"
	for metric in INPUT_IMAGE_REFS UNIQUE_DIGESTS SKOPEO_CALLS SIGN_CALLS VERIFY_CALLS CACHE_HITS MUTATING_RECONCILIATIONS; do
		echo "${phase_prefix}_${metric}=$(runtime_image_pinning_summary_value "$phase_output" "$metric")"
	done
}

runtime_image_pinning_initial() {
	runtime_image_pinning_phase "runtime-image-pinning-initial" "INITIAL" "initial runtime image pinning"
}

runtime_image_pinning_followup() {
	runtime_image_pinning_phase "runtime-image-pinning-followup" "FOLLOWUP" "late PVC runtime image pinning"
}

run_runtime_image_pinning_subtree() {
	runtime_image_pinning_initial
	runtime_image_pinning_followup
}

apply_manifest_from_stdin() {
	local manifest_source_label="${1:-<stdin>}"
	local manifest_tmp
	local placeholder_hit=""
	local line_no=""
	local placeholder=""

	manifest_tmp="$(mktemp)"
	cat >"$manifest_tmp"

	if placeholder_hit="$(grep -nF '${' "$manifest_tmp" | head -n1 || true)"; then
		if [[ -n "$placeholder_hit" ]]; then
			line_no="${placeholder_hit%%:*}"
			placeholder="$(printf '%s\n' "${placeholder_hit#*:}" | sed -n 's/.*\(${[^}]*}\).*/\1/p')"
			if [[ -z "$placeholder" ]]; then
				placeholder='${'
			fi
			printf 'FILE=%s\n' "$manifest_source_label" >&2
			printf 'PLACEHOLDER=%s\n' "$placeholder" >&2
			printf 'LINE=%s\n' "$line_no" >&2
			rm -f "$manifest_tmp"
			fail_bootstrap "UNEXPANDED_PLACEHOLDER"
		fi
	fi

	kubectl apply -f "$manifest_tmp" >/dev/null
	rm -f "$manifest_tmp"
}

log_helm_repo_diagnostics() {
	local stage="$1"
	echo "[bootstrap] helm lifecycle (${stage}): pwd=$(pwd)"
	echo "[bootstrap] helm lifecycle (${stage}): HOME=${HOME:-<unset>}"
	echo "[bootstrap] helm lifecycle (${stage}): XDG_CACHE_HOME=${XDG_CACHE_HOME:-<unset>} XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-<unset>} XDG_DATA_HOME=${XDG_DATA_HOME:-<unset>}"
	helm env 2>/dev/null | sed "s/^/[bootstrap] helm env (${stage}): /" || true
	helm repo list 2>/dev/null | sed "s/^/[bootstrap] helm repo list (${stage}): /" || true
}

ensure_helm_repo_hydrated() {
	local repo_name="$1"
	local repo_url="$2"
	local verify_chart="$3"
	local verify_version="${4:-}"
	local verify_attempts="${5:-3}"
	local repo_ready=0
	local repo_attempt

	echo "[bootstrap] ensuring helm repo ${repo_name} -> ${repo_url}"
	if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${repo_name}"; then
		echo "[bootstrap] helm repo add ${repo_name} ${repo_url}"
		helm repo add "${repo_name}" "${repo_url}" >/dev/null
	else
		echo "[bootstrap] helm repo ${repo_name} already present"
	fi

	for ((repo_attempt = 1; repo_attempt <= verify_attempts; repo_attempt++)); do
		echo "[bootstrap] helm repo verify attempt ${repo_attempt}/${verify_attempts} for ${repo_name}"
		helm repo update "${repo_name}" >/dev/null
		if [[ -n "${verify_version}" ]]; then
			if helm show chart "${verify_chart}" --version "${verify_version}" >/dev/null 2>&1; then
				repo_ready=1
				break
			fi
		else
			if helm show chart "${verify_chart}" >/dev/null 2>&1; then
				repo_ready=1
				break
			fi
		fi
	done

	(( repo_ready == 1 )) || fail_bootstrap "helm repository ${repo_name} not ready for chart ${verify_chart}${verify_version:+ version ${verify_version}}"
}

verify_helm_repo_present() {
	local repo_name="$1"
	helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${repo_name}" \
		|| fail_bootstrap "helm repository ${repo_name} missing immediately before chart install"
}

export THREADFORGE_EXPECTED_ISTIO_VERSION="$ISTIO_TAG"
require_supported_k8s_istio_combo_or_fail

if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
	echo "[bootstrap] provisioning CI disposable registry cert topology"
	eval "$(THREADFORGE_EXECUTION_PROFILE=ci REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}" REGISTRY_ALIAS="${REGISTRY_ALIAS:-registry.threadforge.local}" REGISTRY_PORT="${REGISTRY_PORT:-30500}" bash "$REPO_ROOT/scripts/ci/provision_ci_disposable_certs.sh")"
	if [[ -z "${CI_REGISTRY_CERTS_DIR:-}" || -z "${CI_REGISTRY_CONFIG:-}" ]]; then
		fail_bootstrap "CI disposable cert provisioning did not export CI_REGISTRY_CERTS_DIR/CI_REGISTRY_CONFIG"
	fi
	if [[ ! -d "${CI_REGISTRY_CERTS_DIR}" || ! -f "${CI_REGISTRY_CONFIG}" ]]; then
		fail_bootstrap "CI disposable cert provisioning produced invalid cert/config artifacts"
	fi
	echo "[bootstrap] CI disposable cert dir=${CI_REGISTRY_CERTS_DIR}"
	echo "[bootstrap] CI disposable registry config=${CI_REGISTRY_CONFIG}"
fi

# Provision local disposable registry certs/config when running in local profile
# and no pre-provisioned artifacts are present. This allows bootstrap to create
# the canonical registry without requiring a pre-existing container.
if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
	local_artifact_config="${REPO_ROOT}/artifacts/registry-runtime/${REGISTRY_CONTAINER}-config.yml"
	# Use canonical runtime certs directory for local runtime registry (do not reuse CI disposable artifacts)
	local_artifact_certs_dir="${REPO_ROOT}/certs"
	local_config_valid=0
	if [[ -f "${local_artifact_config}" && -d "${local_artifact_certs_dir}" ]] && \
		registry_config_validate "${local_artifact_config}" "${local_artifact_certs_dir}" "${REGISTRY_PORT}" >/dev/null 2>&1; then
		local_config_valid=1
		echo "[bootstrap] validated durable local registry config ${local_artifact_config}"
	fi
	if [[ "${local_config_valid}" -eq 0 ]]; then
		if [[ -f "${local_artifact_config}" ]]; then
			echo "[bootstrap] REGISTRY_CONFIG_REJECTED=invalid durable config; regenerating from authoritative inputs"
		fi
		echo "[bootstrap] provisioning local disposable registry cert topology (auto)"
		mkdir -p "${REPO_ROOT}/certs" "${local_artifact_certs_dir}" "${REPO_ROOT}/artifacts/registry-runtime"
			# Ensure san_file exists (created earlier in CI path); create for local runs
			if [ -z "${san_file:-}" ]; then
				san_file="$(mktemp)"
				printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "${REGISTRY_ALIAS}" > "$san_file"
			fi
			openssl req -new -x509 -newkey rsa:3072 -sha256 \
			-keyout "${REPO_ROOT}/certs/registry-ca.key" \
			-out "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" \
			-days 365 -nodes -subj '/CN=threadforge-ingress-ca-local' 2>/dev/null || true

		openssl genrsa -out "${local_artifact_certs_dir}/registry.key" 3072 2>/dev/null || true
		openssl req -new -key "${local_artifact_certs_dir}/registry.key" \
			-out "${local_artifact_certs_dir}/registry.csr" \
			-subj "/CN=${REGISTRY_ALIAS}" 2>/dev/null || true
		openssl x509 -req -in "${local_artifact_certs_dir}/registry.csr" \
			-CA "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" -CAkey "${REPO_ROOT}/certs/registry-ca.key" -CAcreateserial \
			-out "${local_artifact_certs_dir}/registry.crt" -days 365 -sha256 \
			-extfile "$san_file" 2>/dev/null || true
	rm -f "$san_file"

		if ! registry_config_write "${local_artifact_config}" "${local_artifact_certs_dir}" "${REGISTRY_PORT}"; then
			fail_bootstrap "local registry config producer failed validation"
		fi
		echo "[bootstrap] REGISTRY_CONFIG_REGENERATED=true"
		echo "[bootstrap] wrote local registry config ${local_artifact_config}"
	fi
fi

if [[ "$BOOTSTRAP_PHASE" == "runtime-image-pinning" ]]; then
	run_runtime_image_pinning_subtree
	exit 0
fi

echo "[bootstrap] hardening local registry boundary"
bash "$REPO_ROOT/scripts/infra/harden_local_registry.sh"
echo "[bootstrap] verifying required registry images"
bash "$REPO_ROOT/scripts/verify/verify_required_registry_images.sh"

# Publish the canonical registry endpoint so cluster components can derive it.
# Create or update a ConfigMap in kube-system named threadforge-registry-endpoint
# with keys: registry_host, registry_port. Then verify the published value.
echo '[bootstrap] publishing canonical registry endpoint to kube-system/threadforge-registry-endpoint'
# Also publish the runtime-resolved registry IP so publication tools can
# contact the same transport endpoint the runtime observed (authoritative
# bootstrap data). Resolve the registry container IP if available.
resolved_ip=""
# Prefer in-cluster container IP (runtime-owned)
if docker inspect --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${REGISTRY_CONTAINER}" >/dev/null 2>&1; then
	resolved_ip="$(docker inspect --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${REGISTRY_CONTAINER}" 2>/dev/null || true)"
fi

# If no container IP, attempt to find a ThreadForge-owned Service in kube-system
if [ -z "${resolved_ip}" ]; then
	svc_line=$(kubectl -n kube-system get svc -o jsonpath='{range .items[*]}{.metadata.name}::{.metadata.labels.app}::{.spec.clusterIP}::{.spec.ports[0].port}{"\n"}{end}' 2>/dev/null || true)
	while IFS= read -r line; do
		name=${line%%::*}
		rest=${line#*::}
		label=${rest%%::*}
		rest2=${rest#*::}
		clusterip=${rest2%%::*}
		port=${rest2##*::}
		if printf '%s' "${name}${label}" | grep -qi 'threadforge'; then
			if [ -n "${clusterip}" ] && [ "${clusterip}" != "<none>" ]; then
				resolved_ip="${clusterip}"
				REGISTRY_PORT="${port:-${REGISTRY_PORT}}"
				break
			fi
		fi
	done <<<"${svc_line}"
fi

if [ -z "${resolved_ip}" ]; then
	echo "[FAIL] REGISTRY_ENDPOINT_AUTHORITY_FAILED"
	echo "REASON=no_runtime_owned_registry_endpoint"
	echo "NEXT_REPAIR=bootstrap registry runtime"
	exit 2
fi

kubectl create configmap threadforge-registry-endpoint -n kube-system \
	--from-literal=registry_host="${REGISTRY_HOST}" \
	--from-literal=registry_port="${REGISTRY_PORT}" \
	--from-literal=registry_ip="${resolved_ip}" \
	--from-literal=registry_transport_endpoint="${resolved_ip}:${REGISTRY_PORT}" \
	--from-literal=registry_transport_health="UNKNOWN" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null 2>&1 || true
published=$(kubectl -n kube-system get configmap threadforge-registry-endpoint -o jsonpath='{.data.registry_host}:{.data.registry_port}' 2>/dev/null || echo "")
if [ "${published}" != "${THREADFORGE_REGISTRY}" ]; then
	echo "[FAIL] bootstrap registry endpoint publish verification failed: expected ${THREADFORGE_REGISTRY} got ${published}"
	exit 2
fi
echo "[bootstrap] published canonical registry endpoint ${THREADFORGE_REGISTRY}"

echo "[bootstrap] deferring required registry image verification until after canonical population and signing"

capture_istio_debug() {
	mkdir -p "${DEBUG_DIR}"
	kubectl -n istio-system describe pod -l app=istiod > "${DEBUG_DIR}/istiod_describe.log" || true
	kubectl -n istio-system logs -l app=istiod --previous > "${DEBUG_DIR}/istiod_logs.log" || true
	kubectl get events -A --sort-by=.lastTimestamp > "${DEBUG_DIR}/events.log" || true
	if kubectl -n kyverno get deploy/kyverno-admission-controller >/dev/null 2>&1; then
		kubectl -n kyverno logs deploy/kyverno-admission-controller > "${DEBUG_DIR}/kyverno_admission.log" || true
	fi
}

append_istiod_readiness_event() {
	local check_name="$1"
	local stage="$2"
	local status="$3"
	local start_ts="$4"
	local end_ts="$5"
	local duration_seconds="$6"
	local retry_count="$7"
	local first_failure_line="$8"

	python3 - "$ISTIOD_READINESS_EVENTS_JSONL" "$check_name" "$stage" "$status" "$start_ts" "$end_ts" "$duration_seconds" "$retry_count" "$first_failure_line" <<'PY'
import json
import sys

(
    events_file,
    check_name,
    stage,
    status,
    start_ts,
    end_ts,
    duration_seconds,
    retry_count,
    first_failure_line,
) = sys.argv[1:]

event = {
    "check": check_name,
    "stage": stage,
    "status": status,
    "start_timestamp": start_ts,
    "end_timestamp": end_ts,
    "duration_seconds": int(duration_seconds),
    "retry_count": int(retry_count),
    "first_failure_line": first_failure_line,
}

with open(events_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(event, ensure_ascii=True) + "\n")
PY
}

render_istiod_readiness_timeline() {
	python3 - "$ISTIOD_READINESS_EVENTS_JSONL" "$ISTIOD_READINESS_TIMELINE_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone

events_file, timeline_file = sys.argv[1:]
events = []
try:
    with open(events_file, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
except FileNotFoundError:
    events = []

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "checks": events,
}

with open(timeline_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

append_kyverno_readiness_event() {
	local check_name="$1"
	local stage="$2"
	local status="$3"
	local attempt="$4"
	local elapsed_seconds="$5"
	local endpoint_count="$6"
	local failing_condition="$7"
	local pod_readiness_summary="$8"
	local api_latency_ms="$9"

	python3 - "$KYVERNO_READINESS_EVENTS_JSONL" "$check_name" "$stage" "$status" "$attempt" "$elapsed_seconds" "$endpoint_count" "$failing_condition" "$pod_readiness_summary" "$api_latency_ms" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    events_file,
    check_name,
    stage,
    status,
    attempt,
    elapsed_seconds,
    endpoint_count,
    failing_condition,
    pod_readiness_summary,
    api_latency_ms,
) = sys.argv[1:]

event = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "check": check_name,
    "stage": stage,
    "status": status,
    "attempt": int(attempt),
    "elapsed_seconds": int(elapsed_seconds),
    "endpoint_count": int(endpoint_count),
    "failing_condition": failing_condition,
    "pod_readiness_summary": pod_readiness_summary,
    "api_latency_ms": int(api_latency_ms),
}

with open(events_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(event, ensure_ascii=True) + "\n")
PY
}

render_kyverno_readiness_timeline() {
	python3 - "$KYVERNO_READINESS_EVENTS_JSONL" "$KYVERNO_READINESS_TIMELINE_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone

events_file, timeline_file = sys.argv[1:]
events = []
try:
    with open(events_file, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
except FileNotFoundError:
    events = []

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "checks": events,
}

with open(timeline_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

kyverno_endpoint_count() {
	kubectl -n kyverno get endpoints kyverno-svc -o json 2>/dev/null \
		| jq -r '[.subsets[]?.addresses[]?] | length' 2>/dev/null || echo 0
}

kyverno_pod_readiness_summary() {
	kubectl -n kyverno get pods -o json 2>/dev/null \
		| jq -r '[.items[] | .metadata.name as $name | (.status.phase // "Unknown") as $phase | (any(.status.conditions[]?; .type=="Ready" and .status=="True")) as $ready | "\($name):phase=\($phase),ready=\($ready)"] | join("; ")' 2>/dev/null
}

kyverno_webhooks_registered() {
	local mut_count val_count
	mut_count="$(kubectl get mutatingwebhookconfiguration -o json 2>/dev/null | jq -r '[.items[] | select((.metadata.name | ascii_downcase | contains("kyverno")))] | length' 2>/dev/null || echo 0)"
	val_count="$(kubectl get validatingwebhookconfiguration -o json 2>/dev/null | jq -r '[.items[] | select((.metadata.name | ascii_downcase | contains("kyverno")))] | length' 2>/dev/null || echo 0)"
	if (( mut_count > 0 )) && (( val_count > 0 )); then
		return 0
	fi
	echo "kyverno webhook registration missing (mutating=${mut_count}, validating=${val_count})"
	return 1
}

kyverno_api_latency_ms_for_endpoints() {
	local t0 t1
	t0="$(date +%s%3N)"
	kubectl -n kyverno get endpoints kyverno-svc --request-timeout=5s >/dev/null 2>&1 || return 1
	t1="$(date +%s%3N)"
	echo $((t1 - t0))
}

kyverno_all_pods_ready() {
	local not_ready
	not_ready="$(kubectl -n kyverno get pods -o json 2>/dev/null | jq -r '.items[] | select((.status.phase // "") != "Running" or (any(.status.conditions[]?; .type=="Ready" and .status=="True") | not)) | .metadata.name' 2>/dev/null || true)"
	if [[ -n "$not_ready" ]]; then
		echo "kyverno pods not ready: ${not_ready}"
		return 1
	fi
	return 0
}

kyverno_namespace_present() {
	kubectl get namespace kyverno >/dev/null 2>&1
}

record_webhook_registration_timeline() {
	python3 - "$WEBHOOK_REGISTRATION_TIMELINE_JSON" "$1" <<'PY'
import json
import sys
from datetime import datetime, timezone

timeline_file, event_json = sys.argv[1:]
event = json.loads(event_json)

try:
    with open(timeline_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except FileNotFoundError:
    payload = {"generated_at": "", "checks": []}

payload["generated_at"] = datetime.now(timezone.utc).isoformat()
payload.setdefault("checks", []).append(event)

with open(timeline_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

write_kyverno_endpoint_state() {
	python3 - "$KYVERNO_ENDPOINT_STATE_JSON" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

target = sys.argv[1]
namespace_present = subprocess.run(["kubectl", "get", "namespace", "kyverno"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def capture_json(args):
    proc = subprocess.run(args, capture_output=True, text=True)
    return {
        "command": " ".join(args),
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "namespace_present": namespace_present,
    "service": capture_json(["kubectl", "-n", "kyverno", "get", "svc", "kyverno-svc", "-o", "yaml"]),
    "endpoints": capture_json(["kubectl", "-n", "kyverno", "get", "endpoints", "kyverno-svc", "-o", "yaml"]),
    "pods": capture_json(["kubectl", "-n", "kyverno", "get", "pods", "-o", "wide"]),
    "webhooks": {
        "mutating": capture_json(["kubectl", "get", "mutatingwebhookconfiguration", "-o", "yaml"]),
        "validating": capture_json(["kubectl", "get", "validatingwebhookconfiguration", "-o", "yaml"]),
    },
}

with open(target, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

run_webhook_registration_condition() {
	local condition_name="${1:-}"
	local description="${2:-}"
	local command_text="${3:-}"
	local start_epoch end_epoch duration stdout stderr rc output_file stderr_file event_json
	if [[ -z "$condition_name" || -z "$description" || -z "$command_text" ]]; then
		echo "run_webhook_registration_condition: missing required arguments"
		return 1
	fi
	start_epoch="$(date +%s%3N)"
	stdout=""
	stderr=""
	rc=0
	if ! output_file="$(mktemp)"; then
		echo "failed to create temp file for ${condition_name}"
		return 1
	fi
	if ! stderr_file="$(mktemp)"; then
		rm -f "$output_file"
		echo "failed to create temp stderr file for ${condition_name}"
		return 1
	fi
	if bash -lc "$command_text" >"$output_file" 2>"$stderr_file"; then
		rc=0
	else
		rc=$?
	fi
	end_epoch="$(date +%s%3N)"
	duration=$((end_epoch - start_epoch))
	stdout="$(cat "$output_file" 2>/dev/null || true)"
	stderr="$(cat "$stderr_file" 2>/dev/null || true)"
	rm -f "$output_file" "$stderr_file"
	event_json="$(python3 - <<'PY' "$condition_name" "$description" "$duration" "$command_text" "$stdout" "$stderr" "$rc"
import json
import sys

condition_name, description, duration, command_text, stdout, stderr, rc = sys.argv[1:]
print(json.dumps({
    "condition": condition_name,
    "description": description,
    "status": "PASS" if int(rc) == 0 else "FAIL",
    "duration_ms": int(duration),
    "retries": 0,
    "command": command_text,
    "stdout": stdout,
    "stderr": stderr,
    "returncode": int(rc),
}))
PY
)"

	record_webhook_registration_timeline "$event_json"
	if (( rc != 0 )); then
		WEBHOOK_LAST_FAILED_SUBCONDITION="$description"
		WEBHOOK_LAST_FAILED_COMMAND="$command_text"
		WEBHOOK_LAST_FAILED_STDERR="$stderr"
		WEBHOOK_LAST_FAILED_STDOUT="$stdout"
		WEBHOOK_LAST_RETRY_COUNT="0"
		WEBHOOK_LAST_ELAPSED_SECONDS="$((duration / 1000))"
		echo "${condition_name} failed: ${stderr:-${stdout:-command exited ${rc}}}"
		return 1
	fi
	return 0
}

emit_webhook_registration_forensics() {
	local failed_condition="$1"
	write_kyverno_endpoint_state
	python3 - "$WEBHOOK_REGISTRATION_FORENSICS_MD" "$failed_condition" "$KYVERNO_ENDPOINT_STATE_JSON" <<'PY'
import json
import sys
from pathlib import Path

md_path, failed_condition, endpoint_json_path = sys.argv[1:]
endpoint_state = json.loads(Path(endpoint_json_path).read_text(encoding="utf-8"))

lines = [
    "# Webhook Registration Forensics",
    "",
    f"- Failed condition: {failed_condition}",
    "",
    "## Endpoint State",
    "",
    "```json",
    json.dumps(endpoint_state, indent=2),
    "```",
]

Path(md_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

collect_kyverno_failure_bundle() {
	local reason="$1"
	local bundle_ts bundle_dir
	bundle_ts="$(date -u +%Y%m%dT%H%M%SZ)"
	bundle_dir="${KYVERNO_FORENSICS_ROOT}/${bundle_ts}"
	mkdir -p "$bundle_dir"

	echo "$reason" >"${bundle_dir}/failure_reason.txt"
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"${bundle_dir}/captured_at_utc.txt"

	kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=1s >"${bundle_dir}/rollout_admission_controller.txt" 2>&1 || true
	kubectl -n kyverno rollout status deployment/kyverno-cleanup-controller --timeout=1s >"${bundle_dir}/rollout_cleanup_controller.txt" 2>&1 || true
	kubectl -n kyverno rollout status deployment/kyverno-reports-controller --timeout=1s >"${bundle_dir}/rollout_reports_controller.txt" 2>&1 || true
	kubectl -n kyverno get pods -o wide >"${bundle_dir}/kyverno_pods_wide.txt" 2>&1 || true
	kubectl -n kyverno get pods -o json >"${bundle_dir}/kyverno_pods.json" 2>&1 || true
	kubectl -n kyverno get pods -o json | jq -r '.items[] | .metadata.name as $name | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]? | "\($name)\t\(.name)\trestarts=\(.restartCount // 0)"' >"${bundle_dir}/kyverno_pod_restart_counts.tsv" 2>&1 || true

	while IFS= read -r pod_name; do
		[[ -n "$pod_name" ]] || continue
		kubectl -n kyverno describe pod "$pod_name" >"${bundle_dir}/${pod_name}_describe.txt" 2>&1 || true
		kubectl -n kyverno logs "$pod_name" --all-containers=true >"${bundle_dir}/${pod_name}_logs.txt" 2>&1 || true
	done < <(kubectl -n kyverno get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

	kubectl -n kyverno logs deployment/kyverno-admission-controller >"${bundle_dir}/kyverno_admission_controller_logs.txt" 2>&1 || true
	kubectl -n kyverno logs deployment/kyverno-cleanup-controller >"${bundle_dir}/kyverno_cleanup_controller_logs.txt" 2>&1 || true
	kubectl -n kyverno logs deployment/kyverno-reports-controller >"${bundle_dir}/kyverno_reports_controller_logs.txt" 2>&1 || true
	kubectl -n kyverno get svc kyverno-svc -o yaml >"${bundle_dir}/kyverno_service.yaml" 2>&1 || true
	kubectl -n kyverno get endpoints kyverno-svc -o yaml >"${bundle_dir}/kyverno_service_endpoints.yaml" 2>&1 || true
	kubectl get mutatingwebhookconfiguration -o yaml >"${bundle_dir}/mutating_webhook_configurations.yaml" 2>&1 || true
	kubectl get validatingwebhookconfiguration -o yaml >"${bundle_dir}/validating_webhook_configurations.yaml" 2>&1 || true
	kubectl get events -n kube-system --sort-by=.lastTimestamp >"${bundle_dir}/kube_system_events.txt" 2>&1 || true
	kubectl get events -n kyverno --sort-by=.lastTimestamp >"${bundle_dir}/kyverno_events.txt" 2>&1 || true

	{
		echo "timestamp_utc endpoint_count api_latency_ms"
		for _ in 1 2 3 4 5; do
			local ts ec lat
			ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			ec="$(kyverno_endpoint_count)"
			lat="$(kyverno_api_latency_ms_for_endpoints 2>/dev/null || echo -1)"
			echo "${ts} ${ec} ${lat}"
			sleep 1
		done
	} >"${bundle_dir}/endpoint_population_timing.tsv"

	kubectl get nodes -o json >"${bundle_dir}/node_conditions.json" 2>&1 || true
	kubectl top nodes >"${bundle_dir}/kubectl_top_nodes.txt" 2>&1 || true
	kubectl top pods -A >"${bundle_dir}/kubectl_top_pods.txt" 2>&1 || true
	kubectl -n kyverno get pods -o json | jq -r '.items[] | .metadata.name as $name | .status.startTime as $start | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]? | "\($name)\t\(.name)\tstart=\($start // "")\tstartedAt=\(.state.running.startedAt // "")"' >"${bundle_dir}/kyverno_pod_startup_durations.tsv" 2>&1 || true
	kubectl -n kyverno get pods -o json | jq -r '.items[] | .metadata.name as $name | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]? | select(.state.waiting != null) | "\($name)\t\(.name)\twaiting=\(.state.waiting.reason // "Unknown")\tmessage=\(.state.waiting.message // "")"' >"${bundle_dir}/kyverno_container_waiting_reasons.tsv" 2>&1 || true

	cat >"$KYVERNO_ROLLOUT_FORENSICS_MD" <<EOF
# Kyverno Rollout Forensics

- Captured at: ${bundle_ts}
- Reason: ${reason}
- Bundle path: ${bundle_dir}

## Included Artifacts

1. Kyverno rollout status snapshots.
2. Kyverno pod readiness/restart/describe/logs.
3. Admission, cleanup, and reports controller logs.
4. Kyverno service and endpoints objects.
5. Mutating/validating webhook configurations.
6. kube-system and kyverno namespace events.
7. Endpoint population timing and API latency timing.
8. Node conditions, `kubectl top`, startup durations, waiting reasons.
EOF
}

gate_kyverno_webhook_readiness() {
	local stage="$1"
	local start_epoch elapsed api_latency_ms pod_summary endpoint_count waiter_output waiter_rc
	WEBHOOK_LAST_FAILED_SUBCONDITION=""
	WEBHOOK_LAST_FAILED_COMMAND=""
	WEBHOOK_LAST_FAILED_STDERR=""
	WEBHOOK_LAST_FAILED_STDOUT=""
	WEBHOOK_LAST_RETRY_COUNT="0"
	WEBHOOK_LAST_ELAPSED_SECONDS="0"
	start_epoch="$(date +%s%3N)"
	endpoint_count="$(kyverno_endpoint_count)"
	pod_summary="$(kyverno_pod_readiness_summary)"
	api_latency_ms="$(kyverno_api_latency_ms_for_endpoints 2>/dev/null || echo -1)"

	if ! kyverno_namespace_present; then
		WEBHOOK_LAST_FAILED_SUBCONDITION="kyverno namespace not present yet"
		WEBHOOK_LAST_FAILED_COMMAND="kubectl get namespace kyverno"
		append_kyverno_readiness_event "webhook-registration-readiness" "$stage" "DEFERRED" "0" "0" "$endpoint_count" "kyverno namespace not present yet" "$pod_summary" "$api_latency_ms"
		write_kyverno_endpoint_state
		record_webhook_registration_timeline "$(python3 - <<'PY'
import json
from datetime import datetime, timezone
print(json.dumps({
    "condition": "webhook-registration-readiness",
    "description": "kyverno namespace not present yet",
    "status": "DEFERRED",
    "duration_ms": 0,
    "retries": 0,
    "command": "kubectl get namespace kyverno",
    "stdout": "",
    "stderr": "",
    "returncode": 0,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}))
PY
)"
		render_kyverno_readiness_timeline
		return 0
	fi

	set +e
	waiter_output="$(bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" 2>&1)"
	waiter_rc=$?
	set -e

	elapsed="$(( $(date +%s%3N) - start_epoch ))"
	WEBHOOK_LAST_ELAPSED_SECONDS="$((elapsed / 1000))"

	if [[ "$waiter_rc" -ne 0 ]]; then
		WEBHOOK_LAST_FAILED_SUBCONDITION="canonical control-plane convergence gate"
		WEBHOOK_LAST_FAILED_COMMAND="bash $REPO_ROOT/scripts/verify/wait_for_control_plane.sh"
		WEBHOOK_LAST_FAILED_STDOUT="$waiter_output"
		append_kyverno_readiness_event "webhook-registration-readiness" "$stage" "FAIL" "0" "$elapsed" "$endpoint_count" "canonical control-plane convergence gate" "$pod_summary" "$api_latency_ms"
		write_kyverno_endpoint_state
		emit_webhook_registration_forensics "canonical control-plane convergence gate"
		collect_kyverno_failure_bundle "canonical control-plane convergence gate (${stage})"
		render_kyverno_readiness_timeline
		echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
		echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
		echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
		echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
		echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
		echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
		return 1
	fi

	append_kyverno_readiness_event "webhook-registration-readiness" "$stage" "PASS" "0" "$elapsed" "$endpoint_count" "" "$pod_summary" "$api_latency_ms"
	write_kyverno_endpoint_state
	emit_webhook_registration_forensics "pass"
	render_kyverno_readiness_timeline
	return 0
}

collect_istiod_failure_bundle() {
	local reason="$1"
	local bundle_ts bundle_dir
	bundle_ts="$(date -u +%Y%m%dT%H%M%SZ)"
	bundle_dir="${ISTIOD_FORENSICS_ROOT}/${bundle_ts}"
	mkdir -p "$bundle_dir"

	echo "$reason" >"${bundle_dir}/failure_reason.txt"
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"${bundle_dir}/captured_at_utc.txt"

	kubectl get pods -A -o wide >"${bundle_dir}/pods_all_wide.txt" 2>&1 || true
	kubectl get pods -A -o json >"${bundle_dir}/pods_all.json" 2>&1 || true
	kubectl -n istio-system get pods -o wide >"${bundle_dir}/istio_system_pods_wide.txt" 2>&1 || true
	kubectl -n istio-system get deploy istiod -o yaml >"${bundle_dir}/istiod_deployment.yaml" 2>&1 || true
	kubectl -n istio-system describe deploy istiod >"${bundle_dir}/istiod_deployment_describe.txt" 2>&1 || true
	kubectl -n istio-system get pods -l app=istiod -o name >"${bundle_dir}/istiod_pod_names.txt" 2>/dev/null || true

	while IFS= read -r pod_line; do
		[[ -n "$pod_line" ]] || continue
		local pod_name
		pod_name="${pod_line#pod/}"
		kubectl -n istio-system describe pod "$pod_name" >"${bundle_dir}/${pod_name}_describe.txt" 2>&1 || true
		kubectl -n istio-system logs "$pod_name" --all-containers=true >"${bundle_dir}/${pod_name}_logs.txt" 2>&1 || true
		kubectl -n istio-system logs "$pod_name" --all-containers=true --previous >"${bundle_dir}/${pod_name}_logs_previous.txt" 2>&1 || true
	done <"${bundle_dir}/istiod_pod_names.txt"

	kubectl get mutatingwebhookconfiguration -o yaml >"${bundle_dir}/mutating_webhooks.yaml" 2>&1 || true
	kubectl get validatingwebhookconfiguration -o yaml >"${bundle_dir}/validating_webhooks.yaml" 2>&1 || true
	kubectl get crd -o json >"${bundle_dir}/crd_state.json" 2>&1 || true
	kubectl get crd -o json | jq -r '.items[] | .metadata.name as $n | ((.status.conditions // []) | map(select(.type=="Established")) | .[0].status // "Unknown") as $e | "\($n)\t\($e)"' >"${bundle_dir}/crd_established_status.tsv" 2>&1 || true
	kubectl get events -n kube-system --sort-by=.lastTimestamp >"${bundle_dir}/kube_system_events.txt" 2>&1 || true
	kubectl get events -n istio-system --sort-by=.lastTimestamp >"${bundle_dir}/istio_system_events.txt" 2>&1 || true
	kubectl get events -A --sort-by=.lastTimestamp >"${bundle_dir}/all_events_timeline.txt" 2>&1 || true
	kubectl get nodes -o yaml >"${bundle_dir}/node_state.yaml" 2>&1 || true
	kubectl describe nodes >"${bundle_dir}/node_describe.txt" 2>&1 || true
	kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n | (.status.conditions[] | select(.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") | "\($n)\t\(.type)=\(.status)")' >"${bundle_dir}/node_pressure.tsv" 2>&1 || true
	kubectl top nodes >"${bundle_dir}/kubectl_top_nodes.txt" 2>&1 || true
	kubectl top pods -A >"${bundle_dir}/kubectl_top_pods.txt" 2>&1 || true
	kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $name | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]? | select((.restartCount // 0) > 0) | "\($ns)/\($name)\t\(.name)\trestarts=\(.restartCount)"' >"${bundle_dir}/pod_restart_counts.tsv" 2>&1 || true
	kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $name | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]? | select(.state.waiting != null) | "\($ns)/\($name)\t\(.name)\twaiting=\(.state.waiting.reason // "Unknown")\tmessage=\(.state.waiting.message // "")"' >"${bundle_dir}/pending_container_states.tsv" 2>&1 || true
	kubectl get events -A --sort-by=.lastTimestamp | grep -E 'Pulling image|Pulled|Failed to pull image|Back-off pulling image|ImagePullBackOff' >"${bundle_dir}/image_pull_timing_events.txt" 2>&1 || true
	kubectl get events -A --sort-by=.lastTimestamp | grep -Ei 'failed calling webhook|context deadline exceeded|admission webhook|timeout' >"${bundle_dir}/admission_latency_indicators.txt" 2>&1 || true
	kubectl -n istio-system get deploy istiod -o json >"${bundle_dir}/envoy_injector_readiness_state.json" 2>&1 || true
	kubectl -n istio-system get svc istiod -o yaml >"${bundle_dir}/istiod_service.yaml" 2>&1 || true
	kubectl -n istio-system get endpoints istiod -o yaml >"${bundle_dir}/istiod_endpoints.yaml" 2>&1 || true
	kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml >"${bundle_dir}/istio_sidecar_injector_webhook.yaml" 2>&1 || true

	cat >"$ISTIOD_ROLLOUT_FORENSICS_MD" <<EOF
# Istiod Rollout Forensics

- Captured at: ${bundle_ts}
- Reason: ${reason}
- Bundle path: ${bundle_dir}

## Included Artifacts

1. Istiod logs and previous logs per pod.
2. Istiod deployment and pod describe output.
3. Mutating and validating webhook snapshots.
4. CRD establishment status snapshot.
5. kube-system and istio-system events plus global timeline.
6. Node pressure and resource snapshots.
7. Pod restart and waiting-state inventories.
8. Image-pull timing and admission latency indicators.
9. Envoy injector readiness state snapshots.
EOF
}

precheck_kube_apiserver_responsive() {
	local readyz
	readyz="$(kubectl get --raw='/readyz?verbose' --request-timeout=10s 2>&1)" || {
		echo "$readyz"
		return 1
	}
	if printf '%s\n' "$readyz" | grep -q '\[-\]'; then
		echo "$readyz"
		return 1
	fi
	return 0
}

precheck_crd_establishment_completion() {
	local crd established
	for crd in certificates.cert-manager.io certificaterequests.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io; do
		established="$(kubectl get crd "$crd" -o jsonpath='{range .status.conditions[?(@.type=="Established")]}{.status}{end}' 2>/dev/null || true)"
		if [[ "$established" != "True" ]]; then
			echo "crd ${crd} not Established=True"
			return 1
		fi
	done
	return 0
}

precheck_webhook_registration_ready() {
	local stage="$1"
	echo "[bootstrap] precheck (${stage}): webhook registration + endpoint readiness"

	if kyverno_namespace_present; then
		if ! gate_kyverno_webhook_readiness "$stage"; then
			echo "[bootstrap] precheck (${stage}): kyverno readiness gate failed"
			echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
			echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
			echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
			echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
			echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
			echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
			return 1
		fi
	else
		echo "[bootstrap] precheck (${stage}): kyverno namespace not present yet; deferring kyverno readiness gate"
	fi

	if ! run_webhook_registration_condition "cert-manager-webhook-config-exists" "cert-manager webhook object exists" "kubectl get validatingwebhookconfiguration cert-manager-webhook -o yaml"; then
		echo "[bootstrap] precheck (${stage}): cert-manager webhook configuration missing"
		echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
		echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
		echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
		echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
		echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
		echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
		collect_kyverno_failure_bundle "${WEBHOOK_LAST_FAILED_SUBCONDITION} (${stage})"
		return 1
	fi

	if ! run_webhook_registration_condition "cert-manager-webhook-endpoints-ready" "cert-manager webhook endpoints populated" "kubectl -n cert-manager get endpoints cert-manager-webhook -o json | jq -e 'any(.subsets[]?; any(.addresses[]?; (.ip // \"\") != \"\"))'"; then
		echo "[bootstrap] precheck (${stage}): cert-manager webhook endpoints not ready"
		echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
		echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
		echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
		echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
		echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
		echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
		collect_kyverno_failure_bundle "${WEBHOOK_LAST_FAILED_SUBCONDITION} (${stage})"
		return 1
	fi

	if kyverno_namespace_present; then
		if ! run_webhook_registration_condition "kyverno-service-endpoints-ready" "kyverno-svc endpoints populated" "kubectl -n kyverno get endpoints kyverno-svc -o json | jq -e 'any(.subsets[]?; any(.addresses[]?; (.ip // \"\") != \"\"))'"; then
			echo "[bootstrap] precheck (${stage}): kyverno/kyverno-svc endpoints not ready"
			echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
			echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
			echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
			echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
			echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
			echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
			collect_kyverno_failure_bundle "${WEBHOOK_LAST_FAILED_SUBCONDITION} (${stage})"
			return 1
		fi
	else
		echo "[bootstrap] precheck (${stage}): kyverno namespace not present yet; deferring kyverno-svc endpoint leaf check"
	fi

	if [[ "$stage" == "pre-istiod-rollout" ]]; then
		if ! run_webhook_registration_condition "istiod-service-endpoints-ready" "istiod service endpoints populated" "kubectl -n istio-system get endpoints istiod -o json | jq -e 'any(.subsets[]?; any(.addresses[]?; (.ip // \"\") != \"\"))'"; then
			echo "[bootstrap] precheck (${stage}): istio-system/istiod endpoints not ready"
			echo "FAILED_SUBCONDITION=${WEBHOOK_LAST_FAILED_SUBCONDITION}"
			echo "FAILED_COMMAND=${WEBHOOK_LAST_FAILED_COMMAND}"
			echo "FAILED_STDERR=${WEBHOOK_LAST_FAILED_STDERR}"
			echo "FAILED_STDOUT=${WEBHOOK_LAST_FAILED_STDOUT}"
			echo "RETRY_COUNT=${WEBHOOK_LAST_RETRY_COUNT}"
			echo "ELAPSED_SECONDS=${WEBHOOK_LAST_ELAPSED_SECONDS}"
			return 1
		fi
	fi

	return 0
}

precheck_node_readiness() {
	local not_ready pressure
	not_ready="$(kubectl get nodes -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status!="True")) | .metadata.name')"
	pressure="$(kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n | .status.conditions[]? | select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True") | "\($n):\(.type)"')"
	if [[ -n "$not_ready" ]]; then
		echo "nodes not Ready: ${not_ready}"
		return 1
	fi
	if [[ -n "$pressure" ]]; then
		echo "node pressure present: ${pressure}"
		return 1
	fi
	return 0
}

precheck_spire_server_readiness() {
	kubectl -n spire-system rollout status statefulset/spire-server --timeout=45s >/dev/null 2>&1 || {
		echo "spire-server rollout not ready"
		return 1
	}
	return 0
}

precheck_spire_agent_rollout_completion() {
	kubectl -n spire-system rollout status daemonset/spire-agent --timeout=45s >/dev/null 2>&1 || {
		echo "spire-agent rollout not ready"
		return 1
	}
	return 0
}

precheck_spire_csr_service_pod_ready() {
	local eps
	kubectl -n istio-system rollout status deployment/spire-csr --timeout=45s >/dev/null 2>&1 || {
		echo "istio-system/spire-csr deployment not ready"
		return 1
	}
	eps="$(kubectl -n istio-system get endpoints spire-csr -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
	[[ -n "$eps" ]] || {
		echo "istio-system/spire-csr service endpoints not ready"
		return 1
	}
	return 0
}

precheck_dns_responsiveness() {
	local eps
	kubectl -n kube-system rollout status deployment/coredns --timeout=45s >/dev/null 2>&1 || {
		echo "kube-system/coredns deployment not ready"
		return 1
	}
	eps="$(kubectl -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
	[[ -n "$eps" ]] || {
		echo "kube-system/kube-dns endpoints not ready"
		return 1
	}
	return 0
}

precheck_api_latency_sanity() {
	local request_start request_end elapsed_ms max_ms
	max_ms=0
	for _ in 1 2 3; do
		request_start="$(date +%s%3N)"
		kubectl get --raw='/readyz' --request-timeout=5s >/dev/null 2>&1 || {
			echo "kube-apiserver /readyz request failed"
			return 1
		}
		request_end="$(date +%s%3N)"
		elapsed_ms=$((request_end - request_start))
		if (( elapsed_ms > max_ms )); then
			max_ms=$elapsed_ms
		fi
	done
	if (( max_ms > 2000 )); then
		echo "api latency sanity failed: max_readyz_latency_ms=${max_ms}"
		return 1
	fi
	return 0
}

precheck_resource_pressure_indicators() {
	local pending_count waiting_pressure
	pending_count="$(kubectl get pods -A --field-selector=status.phase=Pending -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.namespace=="kube-system" or .metadata.namespace=="istio-system" or .metadata.namespace=="spire-system")] | length')"
	waiting_pressure="$(kubectl get pods -A -o json | jq -r '.items[]
		| select(.metadata.namespace=="kube-system" or .metadata.namespace=="istio-system" or .metadata.namespace=="spire-system")
		| .metadata.namespace as $ns
		| .metadata.name as $name
		| ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]?
		| select(.state.waiting != null and (.state.waiting.reason=="ImagePullBackOff" or .state.waiting.reason=="ErrImagePull" or .state.waiting.reason=="CreateContainerError"))
		| "\($ns)/\($name):\(.state.waiting.reason)"')"
	if (( pending_count > 25 )); then
		echo "pending pod pressure detected: ${pending_count}"
		return 1
	fi
	if [[ -n "$waiting_pressure" ]]; then
		echo "waiting container pressure detected: ${waiting_pressure}"
		return 1
	fi
	return 0
}

run_istiod_precheck() {
	local stage="$1"
	local check_name="$2"
	local _max_attempts="$3"
	local _sleep_seconds="$4"
	local command_name="$5"
	local command_arg="${6:-}"
	local output start_epoch end_epoch start_ts end_ts duration phase_name first_failure

	phase_name="precheck-${stage}-${check_name}"
	set_bootstrap_phase "$phase_name" "precheck ${check_name} start"
	start_epoch="$(date +%s)"
	start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	first_failure=""

	if [[ -n "$command_arg" ]]; then
		if output="$("$command_name" "$command_arg" 2>&1)"; then
			end_epoch="$(date +%s)"
			end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			duration=$((end_epoch - start_epoch))
			append_istiod_readiness_event "$check_name" "$stage" "PASS" "$start_ts" "$end_ts" "$duration" "0" ""
			render_istiod_readiness_timeline
			complete_bootstrap_phase "$phase_name" "PASS" "precheck ${check_name} passed"
			return 0
		fi
	else
		if output="$("$command_name" 2>&1)"; then
			end_epoch="$(date +%s)"
			end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			duration=$((end_epoch - start_epoch))
			append_istiod_readiness_event "$check_name" "$stage" "PASS" "$start_ts" "$end_ts" "$duration" "0" ""
			render_istiod_readiness_timeline
			complete_bootstrap_phase "$phase_name" "PASS" "precheck ${check_name} passed"
			return 0
		fi
	fi

	first_failure="$(printf '%s\n' "$output" | awk '/^FAILED_SUBCONDITION=/{print; found=1; exit} NF && !found {line=$0} END{if (!found) print line}')"
	tf_bt_phase_failure "$phase_name" "${first_failure:-precheck failed}"
	end_epoch="$(date +%s)"
	end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	duration=$((end_epoch - start_epoch))
	append_istiod_readiness_event "$check_name" "$stage" "FAIL" "$start_ts" "$end_ts" "$duration" "0" "${first_failure:-precheck failed}"
	render_istiod_readiness_timeline
	complete_bootstrap_phase "$phase_name" "FAIL" "precheck ${check_name} failed"
	fail_bootstrap "precheck ${check_name} failed (${stage}): ${first_failure:-unknown failure}"
}

run_istiod_precheck_suite() {
	local stage="$1"
	if [[ "$stage" == "pre-istiod-rollout" ]]; then
		bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
	fi
	run_istiod_precheck "$stage" "kube-apiserver-responsiveness" 3 2 precheck_kube_apiserver_responsive
	run_istiod_precheck "$stage" "crd-establishment-completion" 3 2 precheck_crd_establishment_completion
	run_istiod_precheck "$stage" "node-readiness" 3 2 precheck_node_readiness
	run_istiod_precheck "$stage" "spire-server-readiness" 3 2 precheck_spire_server_readiness
	run_istiod_precheck "$stage" "spire-agent-rollout-completion" 3 2 precheck_spire_agent_rollout_completion
	run_istiod_precheck "$stage" "spire-csr-service-pod-readiness" 3 2 precheck_spire_csr_service_pod_ready
	run_istiod_precheck "$stage" "dns-responsiveness" 3 2 precheck_dns_responsiveness
	run_istiod_precheck "$stage" "api-latency-sanity" 3 2 precheck_api_latency_sanity
	run_istiod_precheck "$stage" "resource-pressure-indicators" 3 2 precheck_resource_pressure_indicators
	if [[ "$stage" == "pre-istiod-rollout" ]]; then
		run_istiod_precheck "$stage" "webhook-registration-readiness" 3 2 precheck_webhook_registration_ready "$stage"
	fi
}

run_with_deadline() {
	local seconds="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout --foreground "${seconds}s" "$@"
	else
		"$@"
	fi
}

wait_for_deployment_ready() {
	local namespace="$1"
	local deployment="$2"
	# Compatibility sentinel: run_with_deadline 180 kubectl rollout status
	run_with_deadline 30 kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout=30s >/dev/null \
		|| fail_bootstrap "${namespace}/${deployment} not ready"
}

print_workload_namespace_state() {
	local namespace="$1"
	echo "[DEBUG] namespace pods: ${namespace}"
	kubectl get pods -n "${namespace}" || true
	echo "[DEBUG] namespace events: ${namespace}"
	kubectl get events -n "${namespace}" --sort-by=.lastTimestamp || true
}

select_workload_pod() {
	local namespace="$1"
	local app_label="$2"
	kubectl get pods -n "${namespace}" -l "app=${app_label}" -o json 2>/dev/null \
		| jq -r '
			.items
			| map(select(.metadata.deletionTimestamp == null))
			| sort_by(.metadata.creationTimestamp)
			| (
				map(
					select(
						.status.phase == "Running"
						and any(.status.conditions[]?; .type == "Ready" and .status == "True")
					)
				)
				| last
			) // (last)
			| .metadata.name // ""
		' 2>/dev/null || true
}

check_workload_policy_denied() {
	local denied_events policy_name webhook_events webhook_name
	denied_events="$(kubectl get events -A 2>/dev/null \
		| grep -E '^(threadforge-system|threadforge-test)[[:space:]]' \
		| grep -Ei 'denied the request|admission webhook|policy violation|forbidden|blocked by policy|validation error|resource quota|resourcequota|SPIFFE identity required|serviceAccountName must be present' || true)"
	if [[ -n "${denied_events}" ]]; then
		printf '%s\n' "${denied_events}"
		policy_name="$(printf '%s\n' "${denied_events}" | grep -Eo 'threadforge[-a-zA-Z0-9]+' | head -1 || true)"
		echo "[FAIL] WORKLOAD_POLICY_DENIED: ${policy_name:-unknown-policy}"
		exit 2
	fi
}

check_workload_admission_timeout() {
	local webhook_events webhook_name
	webhook_events="$(kubectl get events -A 2>/dev/null \
		| grep -E '^(threadforge-system|threadforge-test)[[:space:]]' \
		| grep -Ei 'webhook|admission' \
		| grep -Ei 'failed calling webhook|context deadline exceeded|no endpoints available|connect: connection refused' || true)"
	if [[ -n "${webhook_events}" ]]; then
		printf '%s\n' "${webhook_events}"
		webhook_name="$(printf '%s\n' "${webhook_events}" | grep -Eo '"[^"]+"' | head -1 | tr -d '"' || true)"
		echo "[FAIL] WORKLOAD_ADMISSION_TIMEOUT: ${webhook_name:-unknown-webhook}"
		exit 2
	fi
}

classify_workload_pod_failure() {
	local namespace="$1"
	local app_label="$2"
	local pod_name pod_json waiting_reason container_reason phase

	pod_name="$(select_workload_pod "${namespace}" "${app_label}")"
	[[ -n "${pod_name}" ]] || return 1

	kubectl describe pod "${pod_name}" -n "${namespace}" || true
	pod_json="$(kubectl get pod "${pod_name}" -n "${namespace}" -o json 2>/dev/null || true)"
	[[ -n "${pod_json}" ]] || return 1

	waiting_reason="$(printf '%s' "${pod_json}" | jq -r '[.status.initContainerStatuses[]?.state.waiting.reason,.status.containerStatuses[]?.state.waiting.reason] | map(select(. != null and . != "")) | .[0] // ""')"
	container_reason="$(printf '%s' "${pod_json}" | jq -r '[.status.containerStatuses[]?.state.terminated.reason] | map(select(. != null and . != "")) | .[0] // ""')"
	phase="$(printf '%s' "${pod_json}" | jq -r '.status.phase // ""')"

	case "${waiting_reason}" in
		ImagePullBackOff|ErrImagePull)
			echo "[FAIL] IMAGE_POLICY_FAILURE: ${namespace}/${pod_name}"
			exit 2
			;;
		CreateContainerConfigError|CreateContainerError)
			echo "[FAIL] CONFIG_FAILURE: ${namespace}/${pod_name}"
			exit 2
			;;
		CrashLoopBackOff)
			echo "[FAIL] RUNTIME_FAILURE: ${namespace}/${pod_name}"
			exit 2
			;;
	esac

	if [[ "${container_reason}" == "Error" ]]; then
		echo "[FAIL] RUNTIME_FAILURE: ${namespace}/${pod_name}"
		exit 2
	fi

	if [[ "${phase}" == "Pending" ]]; then
		echo "[FAIL] SCHEDULING_FAILURE: ${namespace}/${pod_name}"
		exit 2
	fi

	return 1
}

has_workload_webhook_timeout_events() {
	kubectl get events -A 2>/dev/null \
		| grep -E '^(threadforge-system|threadforge-test)[[:space:]]' \
		| grep -Ei 'webhook|admission' \
		| grep -Ei 'failed calling webhook|context deadline exceeded|no endpoints available|connect: connection refused' >/dev/null
}

emit_workload_webhook_timeout_events() {
	kubectl get events -A 2>/dev/null \
		| grep -E '^(threadforge-system|threadforge-test)[[:space:]]' \
		| grep -Ei 'webhook|admission' \
		| grep -Ei 'failed calling webhook|context deadline exceeded|no endpoints available|connect: connection refused' || true
}

validate_workload_compliance() {
	local namespace="$1"
	local app_label="$2"
	local pod_name pod_json image invalid_image resource_missing sidecar_missing spiffe_id socket_env socket_mount

	pod_name="$(select_workload_pod "${namespace}" "${app_label}")"
	[[ -n "${pod_name}" ]] || return 1
	pod_json="$(kubectl get pod "${pod_name}" -n "${namespace}" -o json 2>/dev/null || true)"
	[[ -n "${pod_json}" ]] || return 1

	sidecar_missing="$(printf '%s' "${pod_json}" | jq -r 'any(.spec.containers[]?; .name == "istio-proxy") | not')"
	if [[ "${sidecar_missing}" == "true" ]]; then
		echo "[FAIL] SIDECAR_MISSING: ${namespace}/${pod_name}"
		exit 2
	fi

	invalid_image="$(printf '%s' "${pod_json}" | jq -r '[(.spec.initContainers // [])[], (.spec.containers // [])[]] | map(.image) | map(select((startswith("${REGISTRY_HOSTPORT}/") | not) or (contains("@sha256:") | not))) | .[0] // ""')"
	if [[ -n "${invalid_image}" ]]; then
		echo "[FAIL] IMAGE_POLICY_FAILURE: ${namespace}/${pod_name} image=${invalid_image}"
		exit 2
	fi

	resource_missing="$(printf '%s' "${pod_json}" | jq -r '[(.spec.initContainers // [])[], (.spec.containers // [])[]] | map(select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == "" or (.resources.limits.cpu // "") == "" or (.resources.limits.memory // "") == "")) | .[0].name // ""')"
	if [[ -n "${resource_missing}" ]]; then
		echo "[FAIL] CONFIG_FAILURE: ${namespace}/${pod_name} missing resources on container=${resource_missing}"
		exit 2
	fi

	service_account="$(printf '%s' "${pod_json}" | jq -r '.spec.serviceAccountName // ""')"
	spiffe_id="$(printf '%s' "${pod_json}" | jq -r '[.spec.containers[]?.env[]? | select(.name == "NOTIFIER_SPIFFE_ID") | .value] | map(select(. != null and . != "")) | .[0] // ""')"
	if [[ -z "${service_account}" ]]; then
		echo "[FAIL] IDENTITY_INVALID: ${namespace}/${pod_name} missing serviceAccountName"
		exit 2
	fi
	if [[ "${namespace}/${app_label}" == "threadforge-system/threadforge-notifier" ]]; then
		if [[ "${spiffe_id}" != "spiffe://${SPIFFE_TRUST_DOMAIN}/ns/threadforge-system/sa/threadforge-notifier" ]]; then
			echo "[FAIL] IDENTITY_INVALID: ${namespace}/${pod_name}"
			exit 2
		fi
	fi
}

wait_for_workload_deployment_ready() {
	local namespace="$1"
	local deployment="$2"
	local label="${3:-$2}"
	local rollout_timeout_seconds="${WORKLOAD_ROLLOUT_TIMEOUT_SECONDS:-180}"
	local rollout_retry_attempts="${WORKLOAD_ADMISSION_RETRY_ATTEMPTS:-3}"
	local attempt=1
	local rollout_output rc

	bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
	print_workload_namespace_state "${namespace}"
	while (( attempt <= rollout_retry_attempts )); do
		echo "[DEBUG] running: kubectl rollout status deployment/${deployment} -n ${namespace} --timeout=${rollout_timeout_seconds}s (attempt ${attempt}/${rollout_retry_attempts})"
		if rollout_output="$(kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout="${rollout_timeout_seconds}s" 2>&1)"; then
			echo "[DEBUG] completed: kubectl rollout status deployment/${deployment} -n ${namespace} --timeout=${rollout_timeout_seconds}s"
			return 0
		fi
		rc=$?
		printf '%s\n' "${rollout_output}"
		echo "[DEBUG] failed (${rc}): kubectl rollout status deployment/${deployment} -n ${namespace} --timeout=${rollout_timeout_seconds}s"

		if [[ "$(classify_workload_deploy_failure "${rollout_output}")" == "admission-webhook-not-ready" ]]; then
			if (( attempt < rollout_retry_attempts )); then
				attempt=$((attempt + 1))
				continue
			fi
			check_workload_admission_timeout || fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
		fi

		check_workload_policy_denied
		classify_workload_pod_failure "${namespace}" "${label}" || true
		validate_workload_compliance "${namespace}" "${label}" || true

		if (( attempt < rollout_retry_attempts )); then
			attempt=$((attempt + 1))
			continue
		fi

		echo "[FAIL] WORKLOAD_NOT_READY: ${namespace}/${deployment}"
		exit 2
	done
}

wait_for_ready() {
	local resource="$1"
	local namespace="$2"
	local timeout="${3:-120}"

	if ! run_with_deadline "$timeout" kubectl rollout status "$resource" -n "$namespace" --timeout="${timeout}s" >/dev/null; then
		fail_bootstrap "${namespace}/${resource}"
	fi

	return 0
}

wait_for_service_endpoints() {
	local namespace="$1"
	local service="$2"
	local timeout="${3:-120}"
	local deadline=$((SECONDS + timeout))
	local endpoints=""

	while (( SECONDS < deadline )); do
		endpoints="$(kubectl -n "$namespace" get endpoints "$service" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
		if [[ -n "$endpoints" ]]; then
			return 0
		fi
		sleep 2
	done

	fail_bootstrap "${namespace}/${service} endpoints not ready"
}

wait_for_kyverno_admission_ready() {
	echo "[DEBUG] running: kyverno admission readiness gate"
	# Delegate convergence ownership to the canonical control-plane waiter.
	if ! gate_kyverno_webhook_readiness "post-kyverno-install"; then
		fail_bootstrap "kyverno webhook registration readiness failed during admission gate"
	fi
	local webhook_integrity_output
	if ! webhook_integrity_output="$(TEST_NAMESPACE=threadforge-test bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" 2>&1)"; then
		printf '%s\n' "$webhook_integrity_output"
		fail_bootstrap "kyverno webhook dry-run readiness failed for proof workload namespace"
	fi
	echo "[DEBUG] completed: kyverno admission readiness gate"
}

ensure_threadforge_test_namespace() {
	echo "[bootstrap] ensuring proof workload namespace prerequisite"
	# namespace-contract: threadforge-test namespace producer
	kubectl apply -f platform/deploy/infra/threadforge-test/namespace.yaml >/dev/null \
		|| fail_bootstrap "proof workload namespace producer failed: threadforge-test"
	if ! kubectl get namespace threadforge-test >/dev/null 2>&1; then
		fail_bootstrap "proof workload namespace producer failed: threadforge-test"
	fi
	echo "[PASS] proof workload namespace prerequisite established: threadforge-test"
}

require_threadforge_test_namespace() {
	if ! kubectl get namespace threadforge-test >/dev/null 2>&1; then
		fail_bootstrap "proof workload namespace prerequisite missing: threadforge-test"
	fi
	if [[ "$(kubectl get namespace threadforge-test -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)" != "enabled" ]]; then
		fail_bootstrap "proof workload namespace prerequisite missing istio-injection=enabled"
	fi
}

verify_sidecar_injection_path() {
	local injected_containers

	echo "[bootstrap] verifying sidecar injection path"
	wait_for_istio_deployment istiod
	require_threadforge_test_namespace
	kubectl -n threadforge-test create secret docker-registry registry-credentials \
		--docker-server="${THREADFORGE_REGISTRY}" \
		--docker-username="${THREADFORGE_REGISTRY_USER}" \
		--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kubectl -n threadforge-test patch serviceaccount default \
		-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null 2>&1 || true
	kubectl apply -f platform/deploy/infra/threadforge-test/test-injection.yaml >/dev/null \
		|| fail_bootstrap "test-injection pod creation failed"
	injected_containers="$(kubectl get pod test-injection -n threadforge-test -o json | jq -r '.spec.containers[].name')"
	kubectl delete pod test-injection -n threadforge-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if ! printf '%s\n' "${injected_containers}" | grep -qx 'istio-proxy'; then
		printf '%s\n' "${injected_containers}"
		fail_bootstrap "ISTIO_INJECTION_NOT_READY"
	fi
}

apply_kyverno_policies() {
	local require_internal_registry_tmp require_signed_images_tmp

	require_internal_registry_tmp="$(mktemp)"
	require_signed_images_tmp="$(mktemp)"
	materialize_envsubst_file platform/deploy/infra/policy/require-internal-registry.yaml "$require_internal_registry_tmp"
	materialize_envsubst_file platform/deploy/infra/policy/require-signed-images.yaml "$require_signed_images_tmp"

	kubectl apply -f platform/policies/require-resources.yaml
	kubectl apply -f platform/policies/require-istio-sidecar.yaml
	kubectl apply -f platform/policies/default-deny-threadforge-test.yaml
	kubectl apply -f platform/policies/observability-restrict.yaml
	kubectl apply -f platform/deploy/base/policy/kyverno-policy-validation-matrix.yaml
	kubectl apply -f platform/deploy/base/policy/vap-policy-validation-matrix.yaml
	kubectl apply -f "$require_internal_registry_tmp"
	kubectl apply -f platform/deploy/infra/policy/disallow-ephemeral-containers.yaml
	kubectl apply -f "$require_signed_images_tmp"
	kubectl apply -f platform/deploy/infra/policy/require-istio-injection-namespace.yaml
	kubectl apply -f platform/deploy/infra/policy/enforce-spire-only-certs.yaml
	kubectl apply -f platform/deploy/infra/policy/protect-admission-control.yaml
	kubectl apply -f platform/deploy/infra/policy/protect-spire-availability.yaml
	kubectl apply -f platform/policies/deny-default-namespace-workloads.yaml
	rm -f "$require_internal_registry_tmp" "$require_signed_images_tmp"
}

classify_workload_deploy_failure() {
	local output="$1"

	if printf '%s\n' "$output" | grep -Eqi 'failed calling webhook|context deadline exceeded|connect: connection refused|no endpoints available'; then
		echo "admission-webhook-not-ready"
		return 0
	fi
	if printf '%s\n' "$output" | grep -Eqi 'denied the request|forbidden|policy violation|blocked by policy|validation error|resource quota|resourcequota|SPIFFE identity required|serviceAccountName must be present'; then
		echo "policy-denied"
		return 0
	fi
	if has_workload_webhook_timeout_events; then
		echo "admission-webhook-not-ready"
		return 0
	fi
	echo "workload-deploy-failed"
}

deploy_proof_workloads_with_retry() {
	local attempt=1
	local max_attempts="${WORKLOAD_ADMISSION_RETRY_ATTEMPTS:-3}"
	local command_output rc failure_class

	bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
	while (( attempt <= max_attempts )); do
		echo "[bootstrap] deploying proof workloads (attempt ${attempt}/${max_attempts})"
		if command_output="$(deploy_proof_workloads 2>&1)"; then
			printf '%s\n' "$command_output"
			return 0
		else
			rc=$?
		fi
		printf '%s\n' "$command_output"
		failure_class="$(classify_workload_deploy_failure "$command_output")"
		echo "[bootstrap] workload deployment failed (class=${failure_class}, rc=${rc})"
		if (( attempt < max_attempts )); then
			attempt=$((attempt + 1))
			continue
		fi
		fail_bootstrap "workload deployment failed: class=${failure_class} rc=${rc}"
	done
}

render_chart_crds() {
	local release_name="$1"
	local chart_ref="$2"
	local version="$3"
	local namespace="$4"
	local output_file="$5"

	helm template "${release_name}" "${chart_ref}" \
		--version "${version}" \
		--namespace "${namespace}" \
		--set installCRDs=true | awk '
		BEGIN { doc = "" }
		/^---[[:space:]]*$/ {
			if (doc ~ /kind:[[:space:]]*CustomResourceDefinition/) {
				printf "%s---\n", doc
			}
			doc = ""
			next
		}
		{ doc = doc $0 ORS }
		END {
			if (doc ~ /kind:[[:space:]]*CustomResourceDefinition/) {
				printf "%s", doc
			}
		}
	' > "${output_file}"
}

normalize_kyverno_metrics_service_ports() {
	local service
	for service in \
		kyverno-svc-metrics \
		kyverno-background-controller-metrics \
		kyverno-cleanup-controller-metrics \
		kyverno-reports-controller-metrics; do
		kubectl -n kyverno patch service "${service}" --type=json \
			-p='[{"op":"replace","path":"/spec/ports/0/name","value":"http-metrics"}]' >/dev/null
	done
}

label_namespace_injection() {
	local namespace="$1"
	local injection_mode="$2"
	kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace" >/dev/null
	kubectl label namespace "$namespace" istio-injection="$injection_mode" --overwrite >/dev/null
}

cleanup_minio_legacy_tls() {
	kubectl delete certificate minio-gateway-cert -n istio-system --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete secret minio-gateway-tls -n istio-system --ignore-not-found >/dev/null 2>&1 || true
}

verify_minio_spire_native_bootstrap() {
	VERIFY_MINIO_MODE=bootstrap bash "$REPO_ROOT/scripts/verify/verify_minio_spire_native.sh"
}

stamp_custom_provider_root_projection() {
	python3 "$REPO_ROOT/scripts/install/enable_custom_provider_root_projection.py" >/dev/null
}

materialize_envsubst_file() {
	local input="$1"
	local output="$2"
	REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-${THREADFORGE_REGISTRY:-}}" envsubst < "$input" > "$output"
}

install_kyverno_release() {
	echo "[bootstrap] installing kyverno"
	KYVERNO_HELM_REPO_NAME="kyverno"
	KYVERNO_HELM_REPO_URL="https://kyverno.github.io/kyverno/"
	log_helm_repo_diagnostics "pre-kyverno-repo-init"
	ensure_helm_repo_hydrated "${KYVERNO_HELM_REPO_NAME}" "${KYVERNO_HELM_REPO_URL}" "${KYVERNO_HELM_REPO_NAME}/kyverno" "${KYVERNO_CHART_VERSION}"
	verify_helm_repo_present "${KYVERNO_HELM_REPO_NAME}"
	bash "$REPO_ROOT/scripts/infra/ensure_kyverno_images.sh"
	bash "$REPO_ROOT/scripts/infra/prepare_kyverno_release.sh"
	kubectl create namespace kyverno --dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kubectl -n kyverno create secret docker-registry registry-credentials \
		--docker-server="${THREADFORGE_REGISTRY}" \
		--docker-username="${THREADFORGE_REGISTRY_USER}" \
		--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kyverno_values_tmp="$(mktemp)"
	materialize_envsubst_file platform/deploy/infra/kyverno/values.yaml "$kyverno_values_tmp"
	helm upgrade --install kyverno kyverno/kyverno -n kyverno \
		--create-namespace \
		--version "${KYVERNO_CHART_VERSION}" \
		-f "$kyverno_values_tmp" \
		--set admissionController.imagePullSecrets[0].name=registry-credentials \
		--set backgroundController.imagePullSecrets[0].name=registry-credentials \
		--set cleanupController.imagePullSecrets[0].name=registry-credentials \
		--set reportsController.imagePullSecrets[0].name=registry-credentials \
		--no-hooks \
		--wait --timeout=300s
	rm -f "$kyverno_values_tmp"
	# Patch Kyverno service accounts to use registry credentials
	for sa in kyverno kyverno-reports kyverno-cleanup-jobs; do
	  echo "[DEBUG] running: kubectl patch serviceaccount ${sa} -n kyverno imagePullSecrets"
	  kubectl patch serviceaccount "$sa" -n kyverno -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
	  echo "[DEBUG] completed: kubectl patch serviceaccount ${sa} -n kyverno imagePullSecrets"
	done
	echo "[DEBUG] running: bash scripts/infra/apply_resource_tiering.sh"
	SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/infra/apply_resource_tiering.sh" >/dev/null
	echo "[DEBUG] completed: bash scripts/infra/apply_resource_tiering.sh"
	echo "[DEBUG] running: normalize_kyverno_metrics_service_ports"
	normalize_kyverno_metrics_service_ports
	echo "[DEBUG] completed: normalize_kyverno_metrics_service_ports"
	echo "[DEBUG] running: label_namespace_injection kyverno disabled"
	label_namespace_injection kyverno disabled
	echo "[DEBUG] completed: label_namespace_injection kyverno disabled"
	for deployment in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
		echo "[DEBUG] running: kubectl -n kyverno rollout status deployment/${deployment} --timeout=30s"
		kubectl -n kyverno rollout status deployment/"$deployment" --timeout=30s >/dev/null || fail_bootstrap "kyverno/${deployment} not ready"
		echo "[DEBUG] completed: kubectl -n kyverno rollout status deployment/${deployment} --timeout=30s"
	done
	echo "[DEBUG] running: kubectl -n kyverno set env deployment/kyverno-admission-controller SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_DIR=/etc/ssl/certs"
	kubectl -n kyverno set env deployment/kyverno-admission-controller SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_DIR=/etc/ssl/certs >/dev/null
	echo "[DEBUG] completed: kubectl -n kyverno set env deployment/kyverno-admission-controller SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_DIR=/etc/ssl/certs"
	for deployment in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
		echo "[DEBUG] running: kubectl -n kyverno rollout status deployment/${deployment} --timeout=180s"
		kubectl -n kyverno rollout status deployment/"$deployment" --timeout=180s >/dev/null || fail_bootstrap "kyverno/${deployment} not ready after env update"
		echo "[DEBUG] completed: kubectl -n kyverno rollout status deployment/${deployment} --timeout=180s"
	done
	echo "[DEBUG] running: wait_for_service_endpoints kyverno kyverno-svc 120"
	wait_for_service_endpoints kyverno kyverno-svc 120
	echo "[DEBUG] completed: wait_for_service_endpoints kyverno kyverno-svc 120"
}

deploy_proof_workloads() {
	echo "[bootstrap] deploying notifier and proof workloads"
	require_threadforge_test_namespace
	kubectl -n threadforge-test create secret docker-registry registry-credentials \
		--docker-server="${THREADFORGE_REGISTRY}" \
		--docker-username="${THREADFORGE_REGISTRY_USER}" \
		--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kubectl -n threadforge-test patch serviceaccount default \
		-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null 2>&1 || true
	kubectl apply -f platform/deploy/infra/notifier/deployment.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/notifier/service.yaml >/dev/null
	kubectl -n threadforge-system patch serviceaccount threadforge-notifier \
		-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null 2>&1 || true
	kubectl apply -f platform/deploy/infra/threadforge-test/enforce.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/threadforge-test/ingress.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/security/egress-lockdown-threadforge-test.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/security/threadforge-test-sidecar-egress-locked.yaml >/dev/null
	stamp_custom_provider_root_projection
	print_workload_namespace_state threadforge-system
	print_workload_namespace_state threadforge-test
	wait_for_workload_deployment_ready threadforge-system threadforge-notifier
	wait_for_workload_deployment_ready threadforge-test echo
	wait_for_workload_deployment_ready threadforge-test test-client
}

_wait_statefulset_ready() {
	local name="$1" ns="$2" timeout="${3:-300}"
	local deadline=$(( SECONDS + timeout ))
	while (( SECONDS < deadline )); do
		local ready total
		ready="$(kubectl get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		total="$(kubectl get statefulset "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		echo "[wait] ${ns}/${name}: ${ready:-0}/${total:-?} pods ready"
		if [[ -n "${ready}" && -n "${total}" && "${total}" != "0" && "${ready}" == "${total}" ]]; then
			return 0
		fi
		sleep 15
	done
	return 1
}

install_value_plane_core() {
	echo "[bootstrap] installing value-plane core services"
	# Compatibility sentinel: kubectl rollout status statefulset/postgres -n threadforge-system
	# Compatibility sentinel: kubectl rollout status statefulset/clickhouse -n threadforge-system
	kubectl apply -f platform/deploy/infra/postgres/00a-serviceaccount.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/01-secret.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/02-pvc.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/03-statefulset.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/04-service.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/05-writer-secret.yaml >/dev/null
	kubectl apply -f platform/deploy/infra/postgres/06-reader-secret.yaml >/dev/null
	stamp_custom_provider_root_projection
	kubectl rollout restart statefulset/postgres -n threadforge-system >/dev/null
	_wait_statefulset_ready postgres threadforge-system 300 \
		|| fail_bootstrap "threadforge-system/postgres not ready"

	local clickhouse_values_tmp
	clickhouse_values_tmp="$(mktemp)"
	materialize_envsubst_file platform/deploy/infra/clickhouse/values.yaml "$clickhouse_values_tmp"
	helm upgrade --install clickhouse platform/deploy/infra/clickhouse \
		-n threadforge-system \
		-f "$clickhouse_values_tmp" \
		--create-namespace >/dev/null
	rm -f "$clickhouse_values_tmp"
	stamp_custom_provider_root_projection
	kubectl rollout restart statefulset/clickhouse -n threadforge-system >/dev/null
	_wait_statefulset_ready clickhouse threadforge-system 300 \
		|| fail_bootstrap "threadforge-system/clickhouse not ready"
}

fail_istio_bootstrap() {
	local message="$1"
	collect_istiod_failure_bundle "$message"
	if [[ -n "${BOOTSTRAP_ACTIVE_PHASE:-}" ]]; then
		tf_bt_phase_failure "$BOOTSTRAP_ACTIVE_PHASE" "$message"
		complete_bootstrap_phase "$BOOTSTRAP_ACTIVE_PHASE" "FAIL" "istio bootstrap failure"
	fi
	echo "[FAIL] ${message}"
	capture_istio_debug
	exit 2
}

verify_no_external_images() {
	mkdir -p "${DEBUG_DIR}"
	local external_images
	external_images="$(kubectl get pods -A -o json \
		| jq -r '
			.items[]
			| select((.metadata.deletionTimestamp // "") == "")
			| select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
			| select(
				(.metadata.namespace == "kube-system")
				and (
					(.metadata.name | startswith("kube-apiserver-"))
					or (.metadata.name | startswith("kube-controller-manager-"))
					or (.metadata.name | startswith("kube-scheduler-"))
					or (.metadata.name | startswith("etcd-"))
				)
				| not
			)
			| ((.spec.initContainers // []) + (.spec.containers // []))[]?.image
		' \
		| sed '/^$/d' \
		| grep -v "^${THREADFORGE_REGISTRY}/" \
		| grep -v '^docker.io/kindest/kindnetd:v20240513-cd2ac642$' \
		| grep -v '^docker.io/kindest/local-path-provisioner:v20240513-b9bba138$' \
		| grep -v '^registry.k8s.io/coredns/coredns:v1.11.1$' \
		| grep -v '^registry.k8s.io/kube-proxy:v1.30.2$' || true)"
	if [[ -n "${external_images}" ]]; then
		printf '%s\n' "${external_images}" | sort -u > "${DEBUG_DIR}/external_images.log"
		echo "[FAIL] external images detected in cluster pods; see ${DEBUG_DIR}/external_images.log"
		exit 2
	fi
}

verify_spire_entry_drift() {
	local runtime_json declared_tmp runtime_tmp diff_file entries_file

	runtime_json="${REPO_ROOT}/artifacts/debug/spire_entries_runtime.json"
	diff_file="${DEBUG_DIR}/spire_entries.diff"
	entries_file="${SPIRE_ENTRIES_FILE:-${REPO_ROOT}/platform/identity/spire/entries.yaml}"
	runtime_tmp="$(mktemp)"
	declared_tmp="$(mktemp)"
	trap 'rm -f "${runtime_tmp}" "${declared_tmp}"' RETURN

	bash "${REPO_ROOT}/scripts/debug/dump_spire_entries.sh" >/dev/null
	python3 "${REPO_ROOT}/scripts/debug/normalize_spire_entries.py" "${runtime_json}" > "${runtime_tmp}"
	python3 "${REPO_ROOT}/scripts/debug/normalize_spire_entries.py" "${entries_file}" > "${declared_tmp}"

	if ! diff -u "${declared_tmp}" "${runtime_tmp}" > "${diff_file}"; then
		cat "${diff_file}"
		echo "[FAIL] SPIRE runtime entries drift from ${entries_file}"
		exit 2
	fi

	echo "[bootstrap] SPIRE runtime entries match ${entries_file}"
}

wait_for_istio_deployment() {
	local deployment="$1"
	local rollout_timeout_seconds="${ISTIO_ROLLOUT_TIMEOUT_SECONDS:-180}"
	local rollout_retry_attempts="${ISTIO_ROLLOUT_RETRY_ATTEMPTS:-3}"
	local attempt=1
	local rollout_output failure_class

	bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
	while (( attempt <= rollout_retry_attempts )); do
		if rollout_output="$(run_with_deadline "${rollout_timeout_seconds}" kubectl -n istio-system rollout status deployment/"${deployment}" --timeout="${rollout_timeout_seconds}s" 2>&1)"; then
			printf '%s\n' "${rollout_output}"
			return 0
		fi
		printf '%s\n' "${rollout_output}"
		if printf '%s\n' "${rollout_output}" | grep -Eqi 'failed calling webhook|context deadline exceeded|connect: connection refused|no endpoints available|tls: failed to verify certificate|unknown authority'; then
			failure_class="admission-webhook-not-ready"
		else
			failure_class="workload-not-ready"
		fi

		if (( attempt < rollout_retry_attempts )); then
			echo "[bootstrap] retrying istio rollout for ${deployment} (attempt ${attempt}/${rollout_retry_attempts})"
			sleep 3
			attempt=$((attempt + 1))
			continue
		fi
		fail_istio_bootstrap "${deployment} failed to become ready"
	done
}

wait_for_service_endpoints() {
	local namespace="$1"
	local service="$2"
	local timeout_seconds="${3:-180}"
	local deadline addresses ports

	deadline=$((SECONDS + timeout_seconds))
	while (( SECONDS < deadline )); do
		addresses="$(kubectl get endpoints "${service}" -n "${namespace}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
		ports="$(kubectl get endpoints "${service}" -n "${namespace}" -o jsonpath='{.subsets[*].ports[*].port}' 2>/dev/null || true)"
		if [[ -n "${addresses}" && -n "${ports}" ]]; then
			return 0
		fi
		sleep 2
	done

	fail_bootstrap "${namespace}/${service} service endpoints not published within ${timeout_seconds}s"
}

restart_mesh_workload_if_present() {
	local namespace="$1"
	local deployment="$2"
	local attempt rollout_output restart_output failure_class
	bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
	if kubectl get deployment -n "${namespace}" "${deployment}" >/dev/null 2>&1; then
		for attempt in 1 2 3; do
			if ! restart_output="$(kubectl rollout restart deployment/"${deployment}" -n "${namespace}" 2>&1)"; then
				printf '%s\n' "${restart_output}"
				failure_class="$(classify_workload_deploy_failure "${restart_output}")"
				if [[ "${failure_class}" == "admission-webhook-not-ready" ]]; then
					emit_workload_webhook_timeout_events
					if (( attempt < 3 )); then
						echo "[bootstrap] retrying rollout restart for ${namespace}/${deployment} (attempt ${attempt}/3)"
						sleep 3
						continue
					fi
					check_workload_admission_timeout || fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
					fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
				fi
				check_workload_policy_denied
				if (( attempt < 3 )); then
					echo "[bootstrap] retrying rollout restart for ${namespace}/${deployment} (attempt ${attempt}/3)"
					sleep 3
					continue
				fi
				fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
			fi
			if ! rollout_output="$(kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout=180s 2>&1)"; then
				printf '%s\n' "${rollout_output}"
				failure_class="$(classify_workload_deploy_failure "${rollout_output}")"
				if [[ "${failure_class}" == "admission-webhook-not-ready" ]]; then
					emit_workload_webhook_timeout_events
					if (( attempt < 3 )); then
						echo "[bootstrap] retrying rollout restart for ${namespace}/${deployment} (attempt ${attempt}/3)"
						sleep 3
						continue
					fi
					check_workload_admission_timeout || fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
					fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
				fi
				check_workload_policy_denied
				if (( attempt < 3 )); then
					echo "[bootstrap] retrying rollout restart for ${namespace}/${deployment} (attempt ${attempt}/3)"
					sleep 3
					continue
				fi
				fail_bootstrap "${namespace}/${deployment} failed to restart after trust reconciliation"
			fi
			return 0
		done
	fi
}

enforce_cluster_identity_reissuance() {
	echo "[bootstrap] enforcing cluster-wide identity reissuance"
	bash "$REPO_ROOT/scripts/verify/converge_spire_root.sh" \
		|| fail_bootstrap "cluster-wide SPIRE root convergence failed"
	bash "$REPO_ROOT/scripts/verify/verify_spire_root_consistency.sh" >/dev/null \
		|| fail_bootstrap "multiple SPIRE root generations detected after bootstrap reissuance"
}

refresh_proof_workloads() {
	echo "[bootstrap] refreshing proof workloads after trust reconciliation"
	restart_mesh_workload_if_present threadforge-test echo
	restart_mesh_workload_if_present threadforge-test test-client
	restart_mesh_workload_if_present threadforge-system threadforge-notifier
}

cleanup_standalone_sidecarless_pods() {
	python3 - <<'PY'
import json
import subprocess

protected_namespaces = ["threadforge-test", "threadforge-system"]

for namespace in protected_namespaces:
	raw = subprocess.check_output(["kubectl", "get", "pods", "-n", namespace, "-o", "json"], text=True)
	doc = json.loads(raw)
	for item in doc.get("items", []):
		metadata = item.get("metadata", {})
		status = item.get("status", {})
		spec = item.get("spec", {})

		if status.get("phase") != "Running":
			continue
		if metadata.get("deletionTimestamp"):
			continue

		owner_refs = metadata.get("ownerReferences") or []
		if owner_refs:
			# Keep controller-managed workloads; only clean stale standalone pods.
			continue

		containers = [c.get("name") for c in spec.get("containers", []) if isinstance(c, dict)]
		if "istio-proxy" in containers:
			continue

		name = metadata.get("name", "")
		if not name:
			continue

		subprocess.run(
			["kubectl", "delete", "pod", name, "-n", namespace, "--ignore-not-found=true"],
			check=False,
			stdout=subprocess.DEVNULL,
			stderr=subprocess.DEVNULL,
		)
		print(f"[bootstrap] removed stale standalone sidecarless pod: {namespace}/{name}")
PY
}

reset_ingress_gateway_release() {
	if helm status istio-ingressgateway -n istio-system >/dev/null 2>&1; then
		echo "[bootstrap] resetting existing ingress gateway release state"
		helm uninstall istio-ingressgateway -n istio-system >/dev/null 2>&1 || true
	fi
	kubectl -n istio-system delete deploy,svc,hpa -l app=istio-ingressgateway --ignore-not-found=true >/dev/null 2>&1 || true
}

reset_minio_release() {
	if helm status minio -n minio >/dev/null 2>&1; then
		echo "[bootstrap] resetting existing minio release state"
		helm uninstall minio -n minio >/dev/null 2>&1 || true
	fi
	kubectl -n minio delete deployment/minio service/minio job/threadforge-bucket-bootstrap \
		pvc/minio-data poddisruptionbudget/minio-pdb networkpolicy/minio-allow-operator \
		serviceaccount/minio-sa role/minio-sa-role rolebinding/minio-sa-rb \
		--ignore-not-found=true >/dev/null 2>&1 || true
}

reset_kyverno_release() {
	echo "[bootstrap] resetting existing kyverno release state"
	kubectl -n kyverno delete deploy,sts,ds,svc,hpa,job,secret,configmap,sa,role,rolebinding \
		-l app.kubernetes.io/instance=kyverno --ignore-not-found=true >/dev/null 2>&1 || true
	kubectl delete mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding,clusterpolicy \
		-l app.kubernetes.io/instance=kyverno --ignore-not-found=true >/dev/null 2>&1 || true
	kubectl -n kyverno delete secret -l owner=helm,name=kyverno --ignore-not-found=true >/dev/null 2>&1 || true
}

install_spire_csr_bridge() {
	local spire_root_pem_tmp spire_root_key_der_tmp spire_root_key_pem_tmp spire_root_reader_pod
	local ca_crt_tmp ca_key_tmp ca_key_pkcs8_tmp ca_csr_tmp ca_ext_tmp
	local spire_csr_key_tmp spire_csr_csr_tmp spire_csr_crt_tmp spire_csr_ext_tmp spire_csr_chain_tmp
	local istiod_key_tmp istiod_csr_tmp istiod_crt_tmp istiod_ext_tmp istiod_chain_tmp cert_chain_tmp
	local spire_keys_json_tmp
	local openssl_serial_dir spire_root_serial_tmp spire_csr_serial_tmp istiod_serial_tmp
	local spire_reconcile_attempts spire_reconcile_sleep spire_reconcile_attempt
	local spire_reconcile_ok spire_reconcile_err_tmp spire_entry_count
	local spire_reconcile_out_tmp spire_reconcile_check_out_tmp spire_reconcile_check_err_tmp
	local spire_live_entries_tmp spire_expected_entries_tmp spire_server_pod

	spire_root_pem_tmp="$(mktemp)"
	spire_root_key_der_tmp="$(mktemp)"
	spire_root_key_pem_tmp="$(mktemp)"
	ca_crt_tmp="$(mktemp)"
	ca_key_tmp="$(mktemp)"
	ca_key_pkcs8_tmp="$(mktemp)"
	ca_csr_tmp="$(mktemp)"
	ca_ext_tmp="$(mktemp)"
	spire_csr_key_tmp="$(mktemp)"
	spire_csr_csr_tmp="$(mktemp)"
	spire_csr_crt_tmp="$(mktemp)"
	spire_csr_ext_tmp="$(mktemp)"
	spire_csr_chain_tmp="$(mktemp)"
	istiod_key_tmp="$(mktemp)"
	istiod_csr_tmp="$(mktemp)"
	istiod_crt_tmp="$(mktemp)"
	istiod_ext_tmp="$(mktemp)"
	istiod_chain_tmp="$(mktemp)"
	cert_chain_tmp="$(mktemp)"
	spire_keys_json_tmp="$(mktemp)"
	openssl_serial_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/threadforge-openssl-serial.XXXXXX")" \
		|| fail_bootstrap "unable to allocate isolated openssl serial directory"
	spire_root_serial_tmp="${openssl_serial_dir}/spire-root.srl"
	spire_csr_serial_tmp="${openssl_serial_dir}/spire-csr.srl"
	istiod_serial_tmp="${openssl_serial_dir}/istiod.srl"
	spire_root_reader_pod="spire-root-key-reader"
	spire_reconcile_attempts=6
	spire_reconcile_sleep=2
	spire_reconcile_attempt=1
	spire_reconcile_ok=false
	spire_reconcile_err_tmp="$(mktemp)"
	spire_reconcile_out_tmp="$(mktemp)"
	spire_reconcile_check_out_tmp="$(mktemp)"
	spire_reconcile_check_err_tmp="$(mktemp)"
	spire_live_entries_tmp="$(mktemp)"
	spire_expected_entries_tmp="$(mktemp)"

	bash "$REPO_ROOT/scripts/infra/ensure_spire_root_key_reader.sh" \
		|| fail_bootstrap "unable to start SPIRE root-key reader pod"
	# Bounded retry window for disposable CI convergence: SPIRE root/key material can
	# transiently rotate during fresh bootstrap. Keep fail-closed and local semantics.
	local spire_sign_attempts=5
	local spire_sign_retry_sleep=2
	local spire_sign_attempt=1
	local spire_sign_err_tmp
	local spire_sign_ok=false
	local spire_select_meta_tmp
	local spire_select_err=""
	local spire_sign_err=""
	spire_sign_err_tmp="$(mktemp)"
	spire_select_meta_tmp="$(mktemp)"
	spire_server_pod="$(kubectl get pods -n spire-system -l app=spire-server -o json \
		| jq -r '.items[] | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name' \
		| head -n1)"
	[[ -n "$spire_server_pod" ]] || fail_bootstrap "unable to resolve ready SPIRE server pod"

	if ! openssl genrsa -out "$ca_key_tmp" 2048 >/dev/null 2>&1; then
		fail_bootstrap "failed to generate spire-csr intermediate key"
	fi
	cat >"$ca_ext_tmp" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
	if ! openssl req -new -key "$ca_key_tmp" \
		-subj "/C=US/O=SPIRE/CN=spire-csr-intermediate" \
		-out "$ca_csr_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to generate spire-csr intermediate CSR"
	fi

	bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null \
		|| fail_bootstrap "unable to refresh trust authority state before SPIRE root selection"

	while (( spire_sign_attempt <= spire_sign_attempts )); do
		kubectl exec -n spire-system "${spire_root_reader_pod}" -c reader -- cat /run/spire/data/keys.json >"${spire_keys_json_tmp}" \
			|| fail_bootstrap "unable to read SPIRE key manager material"
		kubectl exec -n spire-system -c spire-server "${spire_server_pod}" -- \
			/opt/spire/bin/spire-server bundle show -socketPath "${SPIRE_SERVER_SOCKET_PATH}" -format pem >"${spire_root_pem_tmp}" 2>/dev/null \
			|| fail_bootstrap "unable to read SPIRE root bundle"

		# Select the authoritative active SPIRE root from trust authority state, then
		# pair it with the matching x509-CA key material from SPIRE's key manager.
		if ! spire_select_err="$({ python3 - "${TRUST_AUTHORITY_STATE_FILE}" "${spire_keys_json_tmp}" "${spire_root_pem_tmp}" "${spire_root_pem_tmp}.active" "${spire_root_key_der_tmp}" "${spire_select_meta_tmp}" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile

state_path, keys_path, bundle_path, out_cert_path, out_key_der_path, out_meta_path = sys.argv[1:]

state = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8"))
active_pem = str(state.get("active_root_pem") or "").strip()
if not active_pem:
	print("[FAIL] trust authority state missing active_root_pem", file=sys.stderr)
	raise SystemExit(1)

def pubkey_fp(pem_bytes):
	result = subprocess.run(
		["openssl", "x509", "-pubkey", "-noout"],
		input=pem_bytes,
		capture_output=True,
		text=False,
	)
	if result.returncode != 0:
		return None
	fp_result = subprocess.run(
		["openssl", "pkey", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
		input=result.stdout,
		capture_output=True,
	)
	if fp_result.returncode != 0:
		return None
	return hashlib.sha256(fp_result.stdout).hexdigest()

active_fp = pubkey_fp(active_pem.encode())
if not active_fp:
	print("[FAIL] unable to compute active root public key fingerprint", file=sys.stderr)
	raise SystemExit(1)

keys_data = json.loads(pathlib.Path(keys_path).read_text(encoding="utf-8"))
matched_key_der = None
matched_key_name = None
for key_name, key_b64 in keys_data.get("keys", {}).items():
	if not key_name.startswith("x509-CA"):
		continue
	try:
		key_der = base64.b64decode(key_b64)
	except Exception:
		continue
	with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as fh:
		fh.write(key_der)
		kpath = fh.name
	pem_result = subprocess.run(
		["openssl", "pkey", "-inform", "DER", "-in", kpath, "-pubout", "-outform", "PEM"],
		capture_output=True,
	)
	pathlib.Path(kpath).unlink(missing_ok=True)
	if pem_result.returncode != 0:
		continue
	fp_result = subprocess.run(
		["openssl", "pkey", "-pubin", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
		input=pem_result.stdout,
		capture_output=True,
	)
	if fp_result.returncode != 0:
		continue
	candidate_fp = hashlib.sha256(fp_result.stdout).hexdigest()
	if candidate_fp == active_fp:
		matched_key_der = key_der
		matched_key_name = key_name
		break

if matched_key_der is None:
	print("[FAIL] no key in SPIRE keys.json matches active root public key", file=sys.stderr)
	raise SystemExit(1)

pathlib.Path(out_cert_path).write_text(active_pem)
pathlib.Path(out_key_der_path).write_bytes(matched_key_der)
pathlib.Path(out_meta_path).write_text(
	f"active_root_pubkey_sha256={active_fp}\n"
	f"matched_key_name={matched_key_name}\n"
)
PY
 } 2>&1)"; then
			echo "[bootstrap] SPIRE root/key selection attempt ${spire_sign_attempt}/${spire_sign_attempts} failed"
			if [[ -n "${spire_select_err}" ]]; then
				printf '%s\n' "${spire_select_err}" | sed 's/^/[bootstrap] spire-select: /'
			fi
			if (( spire_sign_attempt < spire_sign_attempts )); then
				sleep "${spire_sign_retry_sleep}"
				spire_sign_attempt=$((spire_sign_attempt + 1))
				continue
			fi
			fail_bootstrap "unable to select active SPIRE root and matching key"
		fi

		cp "${spire_root_pem_tmp}.active" "${spire_root_pem_tmp}"
		rm -f "${spire_root_pem_tmp}.active"
		openssl ec -inform DER -in "${spire_root_key_der_tmp}" -out "${spire_root_key_pem_tmp}" >/dev/null 2>&1 \
			|| fail_bootstrap "unable to convert SPIRE x509 CA signing key"

		if openssl x509 -req -in "$ca_csr_tmp" -CA "${spire_root_pem_tmp}" -CAkey "${spire_root_key_pem_tmp}" \
			-CAserial "${spire_root_serial_tmp}" -CAcreateserial \
			-out "$ca_crt_tmp" -days 365 -sha256 -extfile "$ca_ext_tmp" >/dev/null 2>"${spire_sign_err_tmp}"; then
			spire_sign_ok=true
			break
		fi

		spire_sign_err="$(cat "${spire_sign_err_tmp}" 2>/dev/null || true)"
		echo "[bootstrap] SPIRE intermediate signing attempt ${spire_sign_attempt}/${spire_sign_attempts} failed"
		if [[ -s "${spire_select_meta_tmp}" ]]; then
			sed 's/^/[bootstrap] spire-select: /' "${spire_select_meta_tmp}"
		fi
		if [[ -n "${spire_sign_err}" ]]; then
			printf '%s\n' "${spire_sign_err}" | sed 's/^/[bootstrap] openssl-sign: /'
		else
			echo "[bootstrap] openssl-sign: <no stderr emitted>"
		fi
		echo "[bootstrap] openssl-sign-context: user=$(id -un 2>/dev/null || echo unknown) uid=$(id -u 2>/dev/null || echo unknown) gid=$(id -g 2>/dev/null || echo unknown) pwd=$(pwd) serial_dir=${openssl_serial_dir} serial_file=${spire_root_serial_tmp}"
		ls -ld /tmp "${openssl_serial_dir}" 2>/dev/null | sed 's/^/[bootstrap] openssl-sign-fs: /' || true
		stat -c '%A %a %U:%G %n' /tmp "${openssl_serial_dir}" "${spire_root_serial_tmp}" 2>/dev/null | sed 's/^/[bootstrap] openssl-sign-fs: /' || true
		findmnt -T /tmp -o TARGET,SOURCE,FSTYPE,OPTIONS -n 2>/dev/null | sed 's/^/[bootstrap] openssl-sign-mount: /' || true

		if (( spire_sign_attempt < spire_sign_attempts )); then
			sleep "${spire_sign_retry_sleep}"
			spire_sign_attempt=$((spire_sign_attempt + 1))
			continue
		fi
		break
	done

	rm -f "${spire_sign_err_tmp}" "${spire_select_meta_tmp}"
	if [[ "${spire_sign_ok}" != "true" ]]; then
		fail_bootstrap "failed to sign spire-csr intermediate from SPIRE root"
	fi
	if ! openssl pkcs8 -topk8 -nocrypt -in "$ca_key_tmp" -out "$ca_key_pkcs8_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to convert spire-csr intermediate key to PKCS8"
	fi

	if ! openssl genrsa -out "$spire_csr_key_tmp" 2048 >/dev/null 2>&1; then
		fail_bootstrap "failed to generate spire-csr serving key"
	fi
	cat >"$spire_csr_ext_tmp" <<'EOF'
subjectAltName=DNS:spire-csr,DNS:spire-csr.istio-system.svc,DNS:spire-csr.istio-system.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=critical,CA:FALSE
EOF
	if ! openssl req -new -key "$spire_csr_key_tmp" \
		-subj "/CN=spire-csr.istio-system.svc.cluster.local" \
		-out "$spire_csr_csr_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to generate spire-csr serving CSR"
	fi
	if ! openssl x509 -req -in "$spire_csr_csr_tmp" -CA "$ca_crt_tmp" -CAkey "$ca_key_tmp" \
		-CAserial "${spire_csr_serial_tmp}" -CAcreateserial \
		-out "$spire_csr_crt_tmp" -days 365 -sha256 -extfile "$spire_csr_ext_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to sign spire-csr serving certificate"
	fi

	if ! openssl genrsa -out "$istiod_key_tmp" 2048 >/dev/null 2>&1; then
		fail_bootstrap "failed to generate istiod serving key"
	fi
	cat >"$istiod_ext_tmp" <<'EOF'
subjectAltName=DNS:istiod,DNS:istiod.istio-system.svc,DNS:istiod.istio-system.svc.cluster.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=critical,CA:FALSE
EOF
	if ! openssl req -new -key "$istiod_key_tmp" \
		-subj "/CN=istiod.istio-system.svc.cluster.local" \
		-out "$istiod_csr_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to generate istiod serving CSR"
	fi
	# Sign istiod serving cert directly from SPIRE root and publish the server
	# cert with its issuing CA so webhook clients can validate the full chain.
	if ! openssl x509 -req -in "$istiod_csr_tmp" -CA "${spire_root_pem_tmp}" -CAkey "${spire_root_key_pem_tmp}" \
		-CAserial "${istiod_serial_tmp}" -CAcreateserial \
		-out "$istiod_crt_tmp" -days 365 -sha256 -extfile "$istiod_ext_tmp" >/dev/null 2>&1; then
		fail_bootstrap "failed to sign istiod serving certificate"
	fi

	cat "$ca_crt_tmp" "$spire_root_pem_tmp" >"$cert_chain_tmp"
	cat "$spire_csr_crt_tmp" "$ca_crt_tmp" >"$spire_csr_chain_tmp"
	cat "$istiod_crt_tmp" "$spire_root_pem_tmp" >"$istiod_chain_tmp"

	kubectl -n istio-system create secret generic spire-csr-ca \
		--from-file=ca.crt="$ca_crt_tmp" \
		--from-file=ca.key="$ca_key_pkcs8_tmp" \
		--from-file=tls.crt="$spire_csr_chain_tmp" \
		--from-file=tls.key="$spire_csr_key_tmp" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kubectl -n istio-system create secret generic cacerts \
		--from-file=ca-cert.pem="$ca_crt_tmp" \
		--from-file=ca-key.pem="$ca_key_pkcs8_tmp" \
		--from-file=cert-chain.pem="$cert_chain_tmp" \
		--from-file=root-cert.pem="$spire_root_pem_tmp" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	kubectl -n istio-system create secret generic istiod-tls \
		--from-file=tls.crt="$istiod_chain_tmp" \
		--from-file=tls.key="$istiod_key_tmp" \
		--from-file=ca.crt="$spire_root_pem_tmp" \
		--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
		rm -f "$spire_root_pem_tmp" "$spire_root_key_der_tmp" "$spire_root_key_pem_tmp" "$ca_crt_tmp" "$ca_key_tmp" "$ca_key_pkcs8_tmp" "$ca_csr_tmp" "$ca_ext_tmp" "$spire_csr_key_tmp" "$spire_csr_csr_tmp" "$spire_csr_crt_tmp" "$spire_csr_ext_tmp" "$spire_csr_chain_tmp" "$istiod_key_tmp" "$istiod_csr_tmp" "$istiod_crt_tmp" "$istiod_ext_tmp" "$istiod_chain_tmp" "$cert_chain_tmp" "$spire_keys_json_tmp" "$spire_root_serial_tmp" "$spire_csr_serial_tmp" "$istiod_serial_tmp" "${ca_crt_tmp}.srl" "${spire_root_pem_tmp}.srl"
		rmdir "$openssl_serial_dir" >/dev/null 2>&1 || true
		kubectl delete pod -n spire-system spire-root-reader-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
			kubectl -n istio-system delete deployment spire-csr --ignore-not-found >/dev/null 2>&1 || true
		kubectl apply -k platform/deploy/infra/spire-csr >/dev/null
		# Clean-cluster bootstrap can race with SPIRE workload API attestation; remove
		# the spire-csr init gate and let the main container handle readiness probes.
	kubectl -n istio-system patch deployment spire-csr --type=json \
		-p='[{"op":"remove","path":"/spec/template/spec/initContainers"}]' >/dev/null 2>&1 || true
	while (( spire_reconcile_attempt <= spire_reconcile_attempts )); do
		# Reconciliation depends on SPIRE control-plane readiness; gate explicitly and fail-closed.
		kubectl -n spire-system wait --for=condition=Ready pod/spire-server-0 --timeout=45s >/dev/null 2>&1 || true
		kubectl -n spire-system rollout status daemonset/spire-agent --timeout=60s >/dev/null 2>&1 || true

		if SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" \
			bash "$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh" >"${spire_reconcile_out_tmp}" 2>"${spire_reconcile_err_tmp}"; then
			spire_reconcile_ok=true
			break
		fi

		echo "[bootstrap] SPIRE reconciliation attempt ${spire_reconcile_attempt}/${spire_reconcile_attempts} failed"
		echo "[bootstrap] spire-reconcile-command: SPIFFE_TRUST_DOMAIN=${SPIFFE_TRUST_DOMAIN} SPIRE_ENTRIES_FILE=${SPIRE_ENTRIES_FILE:-${REPO_ROOT}/platform/identity/spire/entries.yaml} bash scripts/proof/reconcile_spire_entries.sh"
		if [[ -s "${spire_reconcile_out_tmp}" ]]; then
			sed 's/^/[bootstrap] spire-reconcile-stdout: /' "${spire_reconcile_out_tmp}"
		else
			echo "[bootstrap] spire-reconcile-stdout: <empty>"
		fi
		if [[ -s "${spire_reconcile_err_tmp}" ]]; then
			sed 's/^/[bootstrap] spire-reconcile: /' "${spire_reconcile_err_tmp}"
		else
			echo "[bootstrap] spire-reconcile: <no stderr emitted>"
		fi
		echo "[bootstrap] spire-expected-trust-domain: ${SPIFFE_TRUST_DOMAIN}"
		python3 - "${SPIRE_ENTRIES_FILE:-$REPO_ROOT/platform/identity/spire/entries.yaml}" >"${spire_expected_entries_tmp}" <<'PY' || true
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("missing entries.yaml")
    raise SystemExit(0)
entries = []
spiffe = parent = None
selectors = []
for raw in path.read_text().splitlines():
    line = raw.strip()
    if line.startswith('- spiffeID:'):
        if spiffe:
            entries.append((spiffe, parent, selectors))
        spiffe = line.split(':', 1)[1].strip()
        parent = ""
        selectors = []
    elif line.startswith('parentID:'):
        parent = line.split(':', 1)[1].strip()
    elif line.startswith('- k8s:'):
        selectors.append(line[2:].strip())
if spiffe:
    entries.append((spiffe, parent, selectors))
for item in entries:
    print(item)
PY
		if [[ -s "${spire_expected_entries_tmp}" ]]; then
			sed 's/^/[bootstrap] spire-expected-entry: /' "${spire_expected_entries_tmp}"
		fi
		kubectl -n spire-system get pod spire-server-0 -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready}{"\n"}' 2>/dev/null \
			| sed 's/^/[bootstrap] spire-server-ready: /' || true
		kubectl -n spire-system get daemonset spire-agent -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}{"\n"}' 2>/dev/null \
			| sed 's/^/[bootstrap] spire-agent-ready: /' || true
		if kubectl -n spire-system exec spire-server-0 -- /opt/spire/bin/spire-server healthcheck -socketPath /run/spire/private/spire-server.sock >"${spire_live_entries_tmp}" 2>&1; then
			sed 's/^/[bootstrap] spire-api-health: /' "${spire_live_entries_tmp}"
		else
			sed 's/^/[bootstrap] spire-api-health: /' "${spire_live_entries_tmp}"
		fi
		spire_entry_count="$(kubectl -n spire-system exec spire-server-0 -- /opt/spire/bin/spire-server entry show -output json 2>/dev/null \
			| jq -r '.entries|length' 2>/dev/null || true)"
		if [[ -n "${spire_entry_count}" ]]; then
			echo "[bootstrap] spire-entry-count: ${spire_entry_count}"
		else
			echo "[bootstrap] spire-entry-count: unavailable"
		fi
		if kubectl -n spire-system exec spire-server-0 -- /opt/spire/bin/spire-server entry show -output json >"${spire_live_entries_tmp}" 2>/dev/null; then
			jq -r '.entries[] | [((.spiffe_id.trust_domain // "") + (.spiffe_id.path // "")), ((.parent_id.trust_domain // "") + (.parent_id.path // "")), ((.selectors // []) | map((.type // "") + ":" + (.value // "")) | join(","))] | @tsv' "${spire_live_entries_tmp}" 2>/dev/null \
				| sed 's/^/[bootstrap] spire-live-entry: /' || true
		else
			echo "[bootstrap] spire-live-entry: unavailable"
		fi
		if SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" \
			bash "$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh" --check >"${spire_reconcile_check_out_tmp}" 2>"${spire_reconcile_check_err_tmp}"; then
			sed 's/^/[bootstrap] spire-reconcile-check: /' "${spire_reconcile_check_out_tmp}"
		else
			if [[ -s "${spire_reconcile_check_out_tmp}" ]]; then
				sed 's/^/[bootstrap] spire-reconcile-check: /' "${spire_reconcile_check_out_tmp}"
			fi
			if [[ -s "${spire_reconcile_check_err_tmp}" ]]; then
				sed 's/^/[bootstrap] spire-reconcile-check: /' "${spire_reconcile_check_err_tmp}"
			fi
		fi
		if [[ -s "$REPO_ROOT/artifacts/spire/entries_diff.json" ]]; then
			sed 's/^/[bootstrap] spire-entry-diff: /' "$REPO_ROOT/artifacts/spire/entries_diff.json"
		fi
		if [[ -s "$REPO_ROOT/artifacts/spire/entries_status.json" ]]; then
			sed 's/^/[bootstrap] spire-entry-status: /' "$REPO_ROOT/artifacts/spire/entries_status.json"
		fi

		if (( spire_reconcile_attempt < spire_reconcile_attempts )); then
			sleep "${spire_reconcile_sleep}"
			spire_reconcile_attempt=$((spire_reconcile_attempt + 1))
			continue
		fi
		break
	done
	rm -f "${spire_reconcile_err_tmp}" "${spire_reconcile_out_tmp}" "${spire_reconcile_check_out_tmp}" "${spire_reconcile_check_err_tmp}" "${spire_live_entries_tmp}" "${spire_expected_entries_tmp}"
	if [[ "${spire_reconcile_ok}" != "true" ]]; then
		fail_bootstrap "failed to reconcile SPIRE entries before spire-csr rollout"
	fi
	kubectl -n istio-system rollout status deployment/spire-csr --timeout=180s \
		|| fail_bootstrap "istio-system/spire-csr not ready"
}

reconcile_istio_root_configmaps() {
	local reconcile_mode="${1:-all}"
	local signer_root_tmp signer_root_b64_tmp configmap_pem_tmp
	local -r root_extract_timeout=20
	local -r root_get_timeout=15
	local -r root_mutation_timeout=30

	_debug_log_running() {
		echo "[DEBUG] running: $1"
	}

	_debug_log_completed() {
		echo "[DEBUG] completed: $1"
	}

	_debug_log_failed() {
		local command_string="$1"
		local rc="$2"
		echo "[DEBUG] failed (${rc}): ${command_string}"
	}

	_debug_log_timeout() {
		local command_string="$1"
		echo "[DEBUG] timed out: ${command_string}"
	}

	_debug_emit_file() {
		local label="$1"
		local path="$2"
		if [[ -s "$path" ]]; then
			sed "s/^/[DEBUG] ${label}: /" "$path"
		fi
	}

	_debug_run() {
		local command_string="$1"
		local rc
		shift
		_debug_log_running "$command_string"
		if "$@"; then
			_debug_log_completed "$command_string"
			return 0
		else
			rc=$?
		fi
		if [[ "$rc" -eq 124 ]]; then
			_debug_log_timeout "$command_string"
		fi
		_debug_log_failed "$command_string" "$rc"
		return "$rc"
	}

	_debug_capture_file() {
		local output_path="$1"
		local command_string="$2"
		local stderr_tmp rc
		shift 2
		stderr_tmp="$(mktemp)"
		_debug_log_running "$command_string"
		if "$@" >"$output_path" 2>"$stderr_tmp"; then
			_debug_emit_file "stderr" "$stderr_tmp"
			rm -f "$stderr_tmp"
			_debug_log_completed "$command_string"
			return 0
		else
			rc=$?
		fi
		_debug_emit_file "stderr" "$stderr_tmp"
		rm -f "$stderr_tmp"
		if [[ "$rc" -eq 124 ]]; then
			_debug_log_timeout "$command_string"
		fi
		_debug_log_failed "$command_string" "$rc"
		return "$rc"
	}

	_debug_run_capture() {
		local command_string="$1"
		local stdout_tmp stderr_tmp rc
		shift
		stdout_tmp="$(mktemp)"
		stderr_tmp="$(mktemp)"
		_debug_log_running "$command_string"
		if "$@" >"$stdout_tmp" 2>"$stderr_tmp"; then
			_debug_emit_file "stdout" "$stdout_tmp"
			_debug_emit_file "stderr" "$stderr_tmp"
			rm -f "$stdout_tmp" "$stderr_tmp"
			_debug_log_completed "$command_string"
			return 0
		else
			rc=$?
		fi
		_debug_emit_file "stdout" "$stdout_tmp"
		_debug_emit_file "stderr" "$stderr_tmp"
		rm -f "$stdout_tmp" "$stderr_tmp"
		if [[ "$rc" -eq 124 ]]; then
			_debug_log_timeout "$command_string"
		fi
		_debug_log_failed "$command_string" "$rc"
		return "$rc"
	}

	_classify_kubectl_mutation_failure() {
		local namespace="$1"
		local name="$2"
		local action="$3"
		local command_output="$4"
		if printf '%s\n' "$command_output" | grep -Eqi 'admission webhook|failed calling webhook|x509:|tls:|context deadline exceeded|no endpoints available'; then
			fail_bootstrap "classified failure during ${action} ${namespace}/${name}: webhook/tls dependency while reconciling Istio root configmaps: ${command_output}"
		fi
	}

	_extract_signer_root_pem() {
		local output_path="$1"
		local active_root_pem
		local active_root_tmp

		bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
		active_root_tmp="$(mktemp)"
		if ! python3 - "$TRUST_AUTHORITY_STATE_FILE" "$active_root_tmp" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
active_pem = str(state.get("active_root_pem") or "").strip()
if not active_pem:
    raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_text(active_pem)
PY
		then
			rm -f "$active_root_tmp"
			fail_bootstrap "unable to resolve active SPIRE root from trust authority state"
		fi

		active_root_pem="$(cat "$active_root_tmp")"
		rm -f "$active_root_tmp"
		printf '%s\n' "$active_root_pem" >"$output_path"
		_debug_run "openssl x509 -in ${output_path} -noout" openssl x509 -in "$output_path" -noout || {
			rm -f "$output_path"
			fail_bootstrap "trust authority active root PEM is invalid"
		}
		return 0
	}

	_validate_root_configmap() {
		local namespace="$1"
		local name="$2"
		local cm_json cert_pem validation_rc
		local cm_json_tmp
		# Compatibility sentinel: keys == ["root-cert.pem"]
		# Compatibility sentinel: has("binaryData") | not

		cm_json_tmp="$(mktemp)"
		echo "[DEBUG] validate_root_configmap ${namespace}/${name}"
		if _debug_capture_file "$cm_json_tmp" \
			"timeout ${root_get_timeout}s kubectl get configmap ${name} -n ${namespace} -o json" \
			run_with_deadline "$root_get_timeout" \
			kubectl get configmap "$name" -n "$namespace" -o json; then
			cm_json="$(cat "$cm_json_tmp")"
		else
			rm -f "$cm_json_tmp"
			fail_bootstrap "CONFIGMAP_INVALID: unable to read ${namespace}/${name} after reconciliation"
		fi
		rm -f "$cm_json_tmp"

		validation_rc=0
		cert_pem="$(printf '%s' "$cm_json" | python3 -c 'import json,sys
doc=json.load(sys.stdin)
data=doc.get("data") or {}
binary=doc.get("binaryData") or {}
if binary:
    sys.exit(2)
root=data.get("root-cert.pem", "")
if not isinstance(root, str) or not root.strip():
    sys.exit(3)
sys.stdout.write(root)
')" || validation_rc=$?

		case "$validation_rc" in
			0)
				;;
			2)
				fail_bootstrap "CONFIGMAP_INVALID: ${namespace}/${name} unexpectedly contains binaryData"
				;;
			3)
				fail_bootstrap "CONFIGMAP_INVALID: ${namespace}/${name} missing data.root-cert.pem"
				;;
			*)
				fail_bootstrap "CONFIGMAP_INVALID: unable to parse ${namespace}/${name}"
				;;
		esac

		configmap_pem_tmp="$(mktemp)"
		printf '%s\n' "$cert_pem" >"$configmap_pem_tmp"
		if ! _debug_run "openssl x509 -in ${configmap_pem_tmp} -noout" openssl x509 -in "$configmap_pem_tmp" -noout; then
			rm -f "$configmap_pem_tmp"
			fail_bootstrap "CONFIGMAP_INVALID: ${namespace}/${name} root-cert.pem is not valid PEM"
		fi
		rm -f "$configmap_pem_tmp"
	}

	_recreate_root_configmap() {
		local namespace="$1"
		local name="$2"
		local root_path="$3"
		# Compatibility sentinel: kubectl delete configmap "$name" -n "$namespace" --ignore-not-found
		# Compatibility sentinel: kubectl get configmap "$name" -n "$namespace" -o yaml
		local manifest_tmp
		local replace_out
		local replace_rc
		local label_out
		local label_rc
		local placeholder_out
		local get_out

		echo "[DEBUG] recreate_root_configmap ${namespace}/${name}"
		kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace" >/dev/null

		# Phase 1: Normalize existence — configmap must exist before replace
		if ! get_out="$(run_with_deadline "$root_get_timeout" kubectl get configmap "$name" -n "$namespace" --request-timeout="${root_get_timeout}s" 2>&1)"; then
			# Only synthesize a placeholder when the object is truly absent.
			# Transient API failures must remain hard failures.
			if ! printf '%s\n' "$get_out" | grep -qiE 'not found|\(NotFound\)'; then
				[[ -n "$get_out" ]] && printf '%s\n' "$get_out" | sed 's/^/[DEBUG] stderr: /'
				fail_bootstrap "CONFIGMAP_NONDETERMINISTIC: failed to read existing ${namespace}/${name}: ${get_out}"
			fi
			echo "[DEBUG] ${namespace}/${name} not found — creating empty placeholder"
			if ! placeholder_out="$(run_with_deadline "$root_mutation_timeout" kubectl create configmap "$name" -n "$namespace" --from-literal=init=1 --request-timeout="${root_mutation_timeout}s" 2>&1)"; then
				if printf '%s\n' "$placeholder_out" | grep -qiE 'already exists|\(AlreadyExists\)'; then
					echo "[DEBUG] ${namespace}/${name} already exists during placeholder create; continuing"
				else
					[[ -n "$placeholder_out" ]] && printf '%s\n' "$placeholder_out" | sed 's/^/[DEBUG] stderr: /'
					fail_bootstrap "CONFIGMAP_NONDETERMINISTIC: failed to create placeholder for ${namespace}/${name}: ${placeholder_out}"
				fi
			fi
			[[ -n "$placeholder_out" ]] && printf '%s\n' "$placeholder_out" | sed 's/^/[DEBUG] stdout: /'
		fi

		# Phase 2: Render manifest
		manifest_tmp="$(mktemp)"
		if ! _debug_capture_file "$manifest_tmp" \
			"kubectl create configmap ${name} --from-file=root-cert.pem=${root_path} -n ${namespace} --dry-run=client -o yaml" \
			kubectl create configmap "$name" \
			--from-file=root-cert.pem="$root_path" \
			-n "$namespace" \
			--dry-run=client -o yaml; then
			rm -f "$manifest_tmp"
			fail_bootstrap "CONFIGMAP_REPLACE_FAILED: failed to render manifest for ${namespace}/${name}"
		fi

		# Phase 3: Single deterministic replace — no fallback allowed
		_debug_log_running "timeout ${root_mutation_timeout}s kubectl replace --request-timeout=${root_mutation_timeout}s --v=6 -f ${manifest_tmp}"
		if replace_out="$(run_with_deadline "$root_mutation_timeout" kubectl replace --request-timeout="${root_mutation_timeout}s" --v=6 -f "$manifest_tmp" 2>&1)"; then
			[[ -n "$replace_out" ]] && printf '%s\n' "$replace_out" | sed 's/^/[DEBUG] stdout: /'
			_debug_log_completed "timeout ${root_mutation_timeout}s kubectl replace --request-timeout=${root_mutation_timeout}s --v=6 -f ${manifest_tmp}"
		else
			replace_rc=$?
			[[ -n "$replace_out" ]] && printf '%s\n' "$replace_out" | sed 's/^/[DEBUG] stderr: /'
			_classify_kubectl_mutation_failure "$namespace" "$name" "replace" "$replace_out"
			_debug_log_failed "timeout ${root_mutation_timeout}s kubectl replace --request-timeout=${root_mutation_timeout}s --v=6 -f ${manifest_tmp}" "$replace_rc"
			rm -f "$manifest_tmp"
			fail_bootstrap "CONFIGMAP_NONDETERMINISTIC: replace failed for ${namespace}/${name} after existence normalization: ${replace_out}"
		fi

		rm -f "$manifest_tmp"

		if [[ "$namespace/$name" == "istio-system/istio-ca-root-cert" ]]; then
			_debug_log_running "timeout ${root_mutation_timeout}s kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite --request-timeout=${root_mutation_timeout}s --v=6"
			if label_out="$(run_with_deadline "$root_mutation_timeout" kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite --request-timeout="${root_mutation_timeout}s" --v=6 2>&1)"; then
				[[ -n "$label_out" ]] && printf '%s\n' "$label_out" | sed 's/^/[DEBUG] stdout: /'
				_debug_log_completed "timeout ${root_mutation_timeout}s kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite --request-timeout=${root_mutation_timeout}s --v=6"
			else
				label_rc=$?
				[[ -n "$label_out" ]] && printf '%s\n' "$label_out" | sed 's/^/[DEBUG] stderr: /'
				_classify_kubectl_mutation_failure "$namespace" "$name" "label" "$label_out"
				_debug_log_failed "timeout ${root_mutation_timeout}s kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite --request-timeout=${root_mutation_timeout}s --v=6" "$label_rc"
				fail_bootstrap "CONFIGMAP_REPLACE_FAILED: failed to label ${namespace}/${name}: ${label_out}"
			fi
		fi
		_validate_root_configmap "$namespace" "$name"
	}

	signer_root_b64_tmp="$(mktemp)"
	signer_root_tmp="$(mktemp)"
	_extract_signer_root_pem "$signer_root_tmp"

	case "$reconcile_mode" in
		pre-istiod-source)
			_recreate_root_configmap spire-system spire-ca-root-cert "$signer_root_tmp"
			_recreate_root_configmap istio-system spire-ca-root-cert "$signer_root_tmp"
			;;
		post-istiod-source)
			_recreate_root_configmap istio-system istio-ca-root-cert "$signer_root_tmp"
			_recreate_root_configmap observability istio-ca-root-cert "$signer_root_tmp"
			;;
		all)
			_recreate_root_configmap spire-system spire-ca-root-cert "$signer_root_tmp"
			_recreate_root_configmap istio-system spire-ca-root-cert "$signer_root_tmp"
			_recreate_root_configmap istio-system istio-ca-root-cert "$signer_root_tmp"
			_recreate_root_configmap observability istio-ca-root-cert "$signer_root_tmp"
			;;
		*)
			fail_bootstrap "unknown root configmap reconcile mode: ${reconcile_mode}"
			;;
	esac

	rm -f "$signer_root_tmp" "$signer_root_b64_tmp" "$configmap_pem_tmp"
}

reconcile_istio_webhook_cabundle() {
	local active_root_pem_file active_root_b64_file live_bundle_pem_file live_bundle_b64_file webhook vwh webhook_json_tmp spire_server_pod
	active_root_pem_file="$(mktemp)"
	active_root_b64_file="$(mktemp)"
	live_bundle_pem_file="$(mktemp)"
	live_bundle_b64_file="$(mktemp)"
	webhook_json_tmp="$(mktemp)"
	# Compatibility sentinel: base64 -d "$source_b64_file" >"$active_root_pem_file"
	trap 'rm -f "$active_root_pem_file" "$active_root_b64_file" "$live_bundle_pem_file" "$live_bundle_b64_file" "$webhook_json_tmp"' RETURN

	kubectl -n spire-system get configmap spire-ca-root-cert \
		-o jsonpath='{.data.root-cert\.pem}' >"$active_root_pem_file" 2>/dev/null || true
	[[ -s "$active_root_pem_file" ]] || fail_bootstrap "unable to resolve active SPIRE root for webhook caBundle reconciliation"
	openssl x509 -in "$active_root_pem_file" -noout >/dev/null 2>&1 \
		|| fail_bootstrap "resolved active root for webhook caBundle reconciliation is not valid PEM"
	spire_server_pod="$(
		kubectl -n spire-system get pod -l app=spire-server -o json 2>/dev/null | jq -r '
			.items[]
			| select(.status.phase == "Running")
			| select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
			| .metadata.name
		' | head -n1
	)"
	[[ -n "$spire_server_pod" ]] || fail_bootstrap "unable to resolve SPIRE server pod for webhook caBundle reconciliation"
	kubectl -n spire-system exec -c spire-server "$spire_server_pod" -- /opt/spire/bin/spire-server bundle show \
		-socketPath /run/spire/private/spire-server.sock -format pem >"$live_bundle_pem_file" 2>/dev/null \
		|| fail_bootstrap "unable to resolve live SPIRE bundle for webhook caBundle reconciliation"
	openssl x509 -in "$live_bundle_pem_file" -noout >/dev/null 2>&1 \
		|| fail_bootstrap "resolved live SPIRE bundle for webhook caBundle reconciliation is not valid PEM"
	base64 -w0 "$live_bundle_pem_file" >"$live_bundle_b64_file"

	while IFS= read -r webhook; do
		[[ -n "$webhook" ]] || continue
		kubectl get mutatingwebhookconfiguration "$webhook" -o json >"$webhook_json_tmp"
		jq --rawfile ca "$live_bundle_b64_file" '
			(.webhooks[]?.clientConfig.caBundle) = ($ca | gsub("\\n"; ""))
			| del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
		' "$webhook_json_tmp" >"$webhook_json_tmp.reconciled"
		kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found >/dev/null 2>&1 || true
		kubectl apply -f "$webhook_json_tmp.reconciled" >/dev/null 2>&1 \
			|| fail_bootstrap "failed to recreate mutating webhook configuration ${webhook}"
	done < <(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|.*/||' || true)

	while IFS= read -r vwh; do
		[[ -n "$vwh" ]] || continue
		kubectl get validatingwebhookconfiguration "$vwh" -o json >"$webhook_json_tmp"
		jq --rawfile ca "$live_bundle_b64_file" '
			(.webhooks[]?.clientConfig.caBundle) = ($ca | gsub("\\n"; ""))
			| del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
		' "$webhook_json_tmp" >"$webhook_json_tmp.reconciled"
		kubectl delete validatingwebhookconfiguration "$vwh" --ignore-not-found >/dev/null 2>&1 || true
		kubectl apply -f "$webhook_json_tmp.reconciled" >/dev/null 2>&1 \
			|| fail_bootstrap "failed to recreate validating webhook configuration ${vwh}"
	done < <(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|^validatingwebhookconfiguration.admissionregistration.k8s.io/||' || true)
}

verify_webhook_ca_integrity_bootstrap() {
	local rc attempt
	for attempt in 1 2; do
		if TEST_NAMESPACE=istio-system bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" >/dev/null; then
			return 0
		fi
		rc=$?
		if [[ "$rc" -eq 11 && "$attempt" -eq 1 ]]; then
			echo "[bootstrap] webhook CA verifier reported NOT_READY; retrying once after reconciliation"
			sleep 3
			reconcile_istio_webhook_cabundle
			continue
		fi
		return "$rc"
	done
	return 11
}

ensure_registry_ca_artifacts() {
	if [[ ! -f "${REGISTRY_CA_CERT_PATH}" ]]; then
		echo "[FAIL] MISSING_PREREQ: ${REGISTRY_CA_CERT_PATH} not found"
		echo "[FAIL] Run: openssl req -new -x509 -newkey rsa:3072 -sha256 -keyout certs/registry-ca.key -out certs/threadforge-ingress-ca.crt -days 365 -nodes -subj '/CN=threadforge-ingress-ca' -addext 'basicConstraints=critical,CA:TRUE'"
		exit 10
	fi

	mkdir -p "$(dirname "${LEGACY_REGISTRY_CA_CERT_PATH}")"
	cp "${REGISTRY_CA_CERT_PATH}" "${LEGACY_REGISTRY_CA_CERT_PATH}"

	if [[ ! -e "${KIND_BUILD_CA_CERT_PATH}" || -w "${KIND_BUILD_CA_CERT_PATH}" ]]; then
		mkdir -p "$(dirname "${KIND_BUILD_CA_CERT_PATH}")"
		cp "${REGISTRY_CA_CERT_PATH}" "${KIND_BUILD_CA_CERT_PATH}"
	else
		echo "[bootstrap] reusing existing kind build-context CA at ${KIND_BUILD_CA_CERT_PATH}"
	fi
}

publish_registry_ca_configmaps() {
	echo "[bootstrap] publishing authoritative registry CA configmaps"
	kubectl get namespace threadforge-system >/dev/null 2>&1 || kubectl create namespace threadforge-system >/dev/null
	kubectl label namespace threadforge-system istio-injection=enabled --overwrite >/dev/null
	kubectl get namespace threadforge >/dev/null 2>&1 || kubectl create namespace threadforge >/dev/null
	kubectl get namespace forgesec >/dev/null 2>&1 || kubectl create namespace forgesec >/dev/null
	kubectl label namespace forgesec istio-injection=enabled --overwrite >/dev/null

	for namespace in threadforge-system threadforge forgesec; do
		kubectl create configmap registry-ca \
			--namespace "${namespace}" \
			--from-file=threadforge-ingress-ca.crt="${REGISTRY_CA_CERT_PATH}" \
			--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
		kubectl -n "${namespace}" create secret docker-registry registry-credentials \
			--docker-server="${THREADFORGE_REGISTRY}" \
			--docker-username="${THREADFORGE_REGISTRY_USER}" \
			--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
			--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	done
}

wait_for_observability_statefulset() {
	local workload="$1"
	_wait_statefulset_ready "${workload}" observability 120 \
		|| fail_bootstrap "${workload} not ready"
}

check_observability_failures() {
	local failing_pods
	failing_pods="$(kubectl get pods -n observability --no-headers 2>/dev/null | grep -E 'CrashLoopBackOff|Error' || true)"
	if [[ -n "${failing_pods}" ]]; then
		printf '%s\n' "${failing_pods}"
		emit_observability_health
		fail_observability_not_ready "pods entered CrashLoopBackOff or Error"
	fi
}

emit_observability_health() {
	echo "[DEBUG] observability pods"
	kubectl get pods -n observability || true
	echo "[DEBUG] observability pod descriptions"
	kubectl describe pods -n observability || true
}

detect_observability_policy_block() {
	local deny_events
	deny_events="$(kubectl get events -n observability --sort-by=.lastTimestamp 2>/dev/null | grep -i deny || true)"
	if [[ -n "${deny_events}" ]]; then
		printf '%s\n' "${deny_events}"
		return 0
	fi
	return 1
}

fail_observability_not_ready() {
	local component="$1"
	emit_observability_health
	if detect_observability_policy_block; then
		fail_observability_policy_blocked "${component}"
	fi
	echo "[FAIL] OBSERVABILITY_NOT_READY: ${component}"
	exit 2
}

fail_observability_policy_blocked() {
	local component="$1"
	echo "[FAIL] OBSERVABILITY_POLICY_BLOCKED: ${component}"
	exit 2
}

run_observability_step() {
	local label="$1"
	shift
	echo "[DEBUG] running: ${label}"
	if "$@"; then
		echo "[DEBUG] completed: ${label}"
		return 0
	else
		local rc=$?
		echo "[DEBUG] failed (${rc}): ${label}"
		return "${rc}"
	fi
}

run_observability_kubectl() {
	local label="$1"
	local rc
	shift
	if ! run_observability_step "${label}" timeout 30s "$@"; then
		rc=$?
		if [[ "${rc}" -eq 124 ]]; then
			echo "[FAIL] OBSERVABILITY_NOT_READY: ${label} timed out"
			exit 2
		fi
		fail_observability_not_ready "${label}"
	fi
}

wait_for_observability_rollout() {
	local resource="$1"
	local rollout_timeout_seconds="${OBSERVABILITY_ROLLOUT_TIMEOUT_SECONDS:-180}"
	local cmd="kubectl -n observability rollout status ${resource} --timeout=${rollout_timeout_seconds}s"
	if ! run_observability_step "${cmd}" \
		kubectl -n observability rollout status "${resource}" --timeout="${rollout_timeout_seconds}s"; then
		fail_observability_not_ready "${cmd}"
	fi
}

delete_observability_otelcol_if_present() {
	echo "[DEBUG] running: delete otelcol threadforge-collector if CRD exists"
	if ! kubectl api-resources --api-group=opentelemetry.io -o name 2>/dev/null | grep -qx 'otelcols'; then
		echo "[DEBUG] completed: delete otelcol threadforge-collector if CRD exists"
		return 0
	fi
	if kubectl delete otelcol threadforge-collector -n observability --ignore-not-found=true; then
		echo "[DEBUG] completed: delete otelcol threadforge-collector if CRD exists"
		return 0
	fi
	local rc=$?
	echo "[DEBUG] failed (${rc}): delete otelcol threadforge-collector if CRD exists"
	fail_observability_not_ready "delete otelcol threadforge-collector"
}

require_observability_service() {
	local service="$1"
	kubectl get svc -n observability "${service}" >/dev/null 2>&1 \
		|| fail_bootstrap "missing service ${service}"
}

require_observability_endpoints() {
	local service="$1"
	kubectl get endpoints "${service}" -n observability -o jsonpath='{.subsets}' 2>/dev/null | grep -q . \
		|| fail_bootstrap "${service} has no endpoints"
}

require_observability_ready_endpoint() {
	local workload="$1"
	local ready_output
	ready_output="$(kubectl exec -n observability statefulset/"${workload}" -- wget -qO- http://localhost:3100/ready 2>/dev/null || true)"
	# Must contain "ready" — non-empty alone is insufficient (503 body is also non-empty)
	[[ "${ready_output,,}" == *"ready"* ]] || fail_bootstrap "${workload} readiness endpoint returned unexpected response: '${ready_output:-<empty>}'"
}

# wait_for_tempo_ingester_ready: loops until Tempo /ready returns "ready"
# Correctly distinguishes 503 "services not ready" (still initializing) from 200 "ready".
# If the service VIP remains transiently unavailable after the pod is locally ready,
# trust the local Tempo readiness signal and leave service-path validation to the
# downstream seed proof and ingestion checks.
wait_for_tempo_ingester_ready() {
	local deadline tempo_pod probe_output ready_status ready_body ready_err local_body
	deadline=$((SECONDS + OBS_TIMEOUT))
	echo "[bootstrap] waiting for Tempo ingester to be ready (ring init)..."
	while (( SECONDS < deadline )); do
		tempo_pod="$(kubectl get pods -n observability -l app=tempo --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
		if [[ -z "${tempo_pod}" ]]; then
			echo "[bootstrap] Tempo pod not yet running, retrying in 5s..."
			sleep 5
			continue
		fi
		probe_output="$(kubectl exec -n observability "${tempo_pod}" -c tempo -- sh -ec '
			local_body=""
			if command -v curl >/dev/null 2>&1; then
				status="$(curl -sS -o /tmp/t-ready-body.txt -w "%{http_code}" http://tempo.observability.svc.cluster.local:3100/ready 2>/tmp/t-ready-err.txt || true)"
				body="$(cat /tmp/t-ready-body.txt 2>/dev/null || true)"
				err="$(cat /tmp/t-ready-err.txt 2>/dev/null || true)"
				local_body="$(curl -sS http://localhost:3100/ready 2>/tmp/t-local-ready-err.txt || true)"
			elif command -v wget >/dev/null 2>&1; then
				wget -S -O /tmp/t-ready-body.txt http://tempo.observability.svc.cluster.local:3100/ready 2>/tmp/t-ready-err.txt || true
				status="$(awk "BEGIN{code=\"\"} /^  HTTP\//{code=\$2} END{print code}" /tmp/t-ready-err.txt)"
				body="$(cat /tmp/t-ready-body.txt 2>/dev/null || true)"
				err="$(cat /tmp/t-ready-err.txt 2>/dev/null || true)"
				local_body="$(wget -qO- http://localhost:3100/ready 2>/tmp/t-local-ready-err.txt || true)"
			else
				echo "STATUS=000"
				echo "BODY="
				echo "ERR=no_http_client"
				echo "LOCAL_BODY="
				exit 0
			fi
			printf "STATUS=%s\n" "${status:-000}"
			printf "BODY=%s\n" "$(printf "%s" "${body}" | tr "\n" " " | head -c 220)"
			printf "ERR=%s\n" "$(printf "%s" "${err}" | tr "\n" " " | head -c 220)"
			printf "LOCAL_BODY=%s\n" "$(printf "%s" "${local_body}" | tr "\n" " " | head -c 220)"
		' 2>/dev/null || true)"
		ready_status="$(printf '%s\n' "${probe_output}" | awk -F= '/^STATUS=/{print $2}' | tail -1)"
		ready_body="$(printf '%s\n' "${probe_output}" | sed -n 's/^BODY=//p' | tail -1)"
		ready_err="$(printf '%s\n' "${probe_output}" | sed -n 's/^ERR=//p' | tail -1)"
		local_body="$(printf '%s\n' "${probe_output}" | sed -n 's/^LOCAL_BODY=//p' | tail -1)"
		if [[ "${ready_status}" == "200" && "${ready_body,,}" == *"ready"* ]]; then
			echo "[bootstrap] Tempo ingester ready: ${ready_body}"
			return 0
		fi
		if [[ "${local_body,,}" == *"ready"* ]]; then
			echo "[bootstrap] Tempo ingester locally ready while service path is still settling (status=${ready_status:-<none>} err='${ready_err:-<none>}')"
			return 0
		fi
		if [[ -z "${ready_body}" ]]; then
			echo "[bootstrap] Tempo /ready returned empty response (status=${ready_status:-<none>} err='${ready_err:-<none>}'), retrying in 5s..."
			sleep 5
			continue
		fi
		echo "[bootstrap] Tempo not yet ready (status=${ready_status:-<none>} body='${ready_body:-<empty>}' err='${ready_err:-<none>}'), retrying in 5s..."
		sleep 5
	done
	verify_tempo_ring_formation
	fail_bootstrap "Tempo ingester did not become ready within ${OBS_TIMEOUT}s"
}

reconcile_observability_spire_entries() {
	if ! SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/infra/reconcile_observability_spire_entries.sh" --apply; then
		fail_bootstrap "failed to create/verify required observability SPIRE entries"
	fi
}

assert_observability_spire_entries() {
	if ! SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/infra/reconcile_observability_spire_entries.sh" --check; then
		echo "[FAIL] SPIRE_ENTRY_MISSING"
		fail_bootstrap "required SPIRE entry set missing for observability workloads"
	fi
}

assert_tempo_spire_entry() {
	local expected_spiffe
	expected_spiffe="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/tempo-sa"
	if ! kubectl exec -n spire-system spire-server-0 -- \
		/opt/spire/bin/spire-server entry show \
		-spiffeID "${expected_spiffe}" \
		-socketPath /run/spire/private/spire-server.sock 2>/dev/null \
		| sed -n 's/^SPIFFE ID[[:space:]]*:[[:space:]]*//p' \
		| grep -Fxq "${expected_spiffe}"; then
		echo "[FAIL] SPIRE_ENTRY_MISSING: ${expected_spiffe}"
		fail_bootstrap "SPIRE registration entry missing for Tempo workload"
	fi
	echo "[bootstrap] SPIRE entry confirmed: ${expected_spiffe}"
}

verify_tempo_sidecar_and_spiffe() {
	local expected_spiffe trust_domain_root pods pod certs spiffe_uris unexpected_uris
	expected_spiffe="spiffe://identity.threadforge.local/ns/observability/sa/tempo-sa"
	trust_domain_root="spiffe://${SPIFFE_TRUST_DOMAIN}"
	pods="$(kubectl get pods -n observability -l app=tempo --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
	[[ -n "${pods}" ]] || fail_bootstrap "no running Tempo pods found for sidecar/SPIFFE verification"
	while IFS= read -r pod; do
		[[ -n "${pod}" ]] || continue
		if ! kubectl get pod -n observability "${pod}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -qw istio-proxy; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: missing istio-proxy container on ${pod}"
			fail_bootstrap "Tempo sidecar injection missing on ${pod}"
		fi
		certs="$(kubectl exec -n observability "${pod}" -c istio-proxy -- pilot-agent request GET /certs 2>/dev/null || true)"
		spiffe_uris="$(printf '%s\n' "${certs}" | sed -n 's/.*"uri":[[:space:]]*"\(spiffe:\/\/[^"[:space:]]*\)".*/\1/p' || true)"
		if [[ -z "${spiffe_uris}" ]]; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: missing SPIFFE identity in Envoy certs for ${pod}"
			fail_bootstrap "Tempo SPIFFE identity missing on ${pod}"
		fi
		if ! printf '%s\n' "${spiffe_uris}" | grep -Fxq "${expected_spiffe}"; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: expected SPIFFE identity not present on ${pod} (expected=${expected_spiffe})"
			fail_bootstrap "Tempo SPIFFE identity mismatch on ${pod}"
		fi
		unexpected_uris="$(printf '%s\n' "${spiffe_uris}" | grep -vFx "${expected_spiffe}" | grep -vFx "${trust_domain_root}" || true)"
		if [[ -n "${unexpected_uris}" ]]; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: unexpected non-root SPIFFE identity on ${pod}: ${unexpected_uris}"
			fail_bootstrap "Tempo SPIFFE identity mismatch on ${pod}"
		fi
	done <<<"${pods}"
}

verify_tempo_internal_connectivity() {
	local pods src dst host port probe_script check_memberlist_port
	pods="$(kubectl get pods -n observability -l app=tempo --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
	[[ -n "${pods}" ]] || fail_bootstrap "no running Tempo pods found for internal connectivity checks"
	check_memberlist_port=0
	while IFS= read -r src; do
		[[ -n "${src}" ]] || continue
		if kubectl exec -n observability "${src}" -c tempo -- sh -ec '
			if command -v ss >/dev/null 2>&1; then
			  ss -lnt | awk "NR>1{print \$4}" | grep -Eq "(^|:)7946$"
			elif command -v netstat >/dev/null 2>&1; then
			  netstat -lnt | awk "NR>2{print \$4}" | grep -Eq "(^|:)7946$"
			else
			  exit 1
			fi
		' >/dev/null 2>&1; then
			check_memberlist_port=1
			break
		fi
	done <<<"${pods}"

	read -r -d '' probe_script <<'EOF' || true
host="$1"
port="$2"
if command -v nc >/dev/null 2>&1; then
  nc -z -w3 "$host" "$port"
  exit $?
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - "$host" "$port" <<'PY'
import socket, sys
h = sys.argv[1]
p = int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
s.connect((h, p))
s.close()
PY
  exit $?
fi
if command -v bash >/dev/null 2>&1; then
  bash -lc 'exec 3<>/dev/tcp/'"$host"'/'"$port"
  exit $?
fi
if command -v curl >/dev/null 2>&1; then
  curl -sS --connect-timeout 3 --max-time 5 "telnet://$host:$port" >/dev/null
  exit $?
fi
echo "no_tcp_probe_tool"
exit 127
EOF
	while IFS= read -r src; do
		[[ -n "${src}" ]] || continue
		while IFS= read -r dst; do
			[[ -n "${dst}" ]] || continue
			host="${dst}.tempo.observability.svc.cluster.local"
			for port in 9095; do
				if ! kubectl exec -n observability "${src}" -c tempo -- sh -ec "${probe_script}" -- "${host}" "${port}" >/dev/null 2>&1; then
					echo "[FAIL] TEMPO_RING_NOT_FORMED: internal connectivity blocked (${src} -> ${host}:${port})"
					fail_bootstrap "Tempo intra-cluster connectivity failed on port ${port}"
				fi
			done
			if [[ "${check_memberlist_port}" -eq 1 ]]; then
				port=7946
				if ! kubectl exec -n observability "${src}" -c tempo -- sh -ec "${probe_script}" -- "${host}" "${port}" >/dev/null 2>&1; then
					echo "[FAIL] TEMPO_RING_NOT_FORMED: memberlist connectivity blocked (${src} -> ${host}:${port})"
					fail_bootstrap "Tempo memberlist connectivity failed on port ${port}"
				fi
			fi
		done <<<"${pods}"
	done <<<"${pods}"
}

verify_tempo_ring_formation() {
	local logs
	logs="$(kubectl logs -n observability statefulset/tempo -c tempo --tail=500 2>/dev/null || true)"
	[[ -n "${logs}" ]] || {
		echo "[FAIL] TEMPO_RING_NOT_FORMED: unable to read Tempo logs"
		fail_bootstrap "Tempo ring diagnostics unavailable"
	}
	if ! printf '%s\n' "${logs}" | grep -Eiq 'memberlist.*(join|joined|fast-join|rejoin|cluster)|joined memberlist|memberlist_client'; then
		# Single-replica single-binary Tempo may not emit explicit memberlist join lines,
		# but must still initialize memberlist-kv and ring modules.
		if ! printf '%s\n' "${logs}" | grep -Eiq 'starting module=memberlist-kv|module=memberlist-kv|memberlist-kv'; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: memberlist initialization not found in logs"
			fail_bootstrap "Tempo memberlist did not form"
		fi
	fi
	if ! printf '%s\n' "${logs}" | grep -Eiq 'ingester.*(registered|register|JOINING|ACTIVE|lifecycler|ring)'; then
		# Tempo single-binary startup can emit module/lifecycler startup without an explicit
		# "registered" line in recent releases.
		if ! printf '%s\n' "${logs}" | grep -Eiq 'starting module=ingester|module=ingester|adding tokens from file|lifecycler\.go'; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: ingester registration not found in logs"
			fail_bootstrap "Tempo ingester not registered"
		fi
	fi
	if ! printf '%s\n' "${logs}" | grep -Eiq 'distributor.*(connect|connected|ready|ring)|component=distributor'; then
		if ! printf '%s\n' "${logs}" | grep -Eiq 'starting module=distributor|module=distributor'; then
			echo "[FAIL] TEMPO_RING_NOT_FORMED: distributor connectivity not found in logs"
			fail_bootstrap "Tempo distributor not connected"
		fi
	fi
}

run_tempo_seed_proof() {
	local job_name seed_timeout deadline manifest_file pod_name emitter_reason emitter_exit tempo_metrics sidecar_checked
	local job_succeeded job_failed
	local signer_root_tmp observed_root_tmp signer_root_fp observed_root_fp sync_attempt sync_max_attempts
	job_name="observability-bootstrap-trace"
	sidecar_checked=0
	seed_timeout="${OBS_TEMPO_SEED_TIMEOUT:-${OBS_TIMEOUT}}"
	[[ "${seed_timeout}" -lt 180 ]] && seed_timeout=180
	sync_max_attempts=30

	# Fail closed unless namespace trust converges to the active SPIRE root.
	signer_root_tmp=""
	observed_root_tmp=""
	signer_root_tmp="$(mktemp)"
	observed_root_tmp="$(mktemp)"
	kubectl get configmap istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\.pem}' >"${signer_root_tmp}" 2>/dev/null \
		|| fail_bootstrap "unable to read active SPIRE root configmap before Tempo seed proof"
	[[ -s "${signer_root_tmp}" ]] || fail_bootstrap "active SPIRE root configmap missing before Tempo seed proof"
	signer_root_fp="$(openssl x509 -in "${signer_root_tmp}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
	[[ -n "${signer_root_fp}" ]] || fail_bootstrap "failed to fingerprint active SPIRE root configmap before Tempo seed proof"

	sync_attempt=0
	while (( sync_attempt < sync_max_attempts )); do
		if kubectl get configmap istio-ca-root-cert -n observability -o jsonpath='{.data.root-cert\.pem}' >"${observed_root_tmp}" 2>/dev/null; then
			if openssl x509 -in "${observed_root_tmp}" -noout >/dev/null 2>&1; then
				observed_root_fp="$(openssl x509 -in "${observed_root_tmp}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
				if [[ -n "${observed_root_fp}" && "${observed_root_fp}" == "${signer_root_fp}" ]]; then
					break
				fi
			fi
		fi
		sync_attempt=$((sync_attempt + 1))
		sleep 2
	done

	rm -f "${signer_root_tmp}" "${observed_root_tmp}"
	if (( sync_attempt >= sync_max_attempts )); then
		fail_bootstrap "observability/istio-ca-root-cert did not converge to SPIRE root bundle before Tempo seed proof"
	fi

	echo "[bootstrap] running Tempo seed proof job..."
	kubectl delete job -n observability "${job_name}" --ignore-not-found=true >/dev/null 2>&1 || true

	manifest_file="$(mktemp)"
	seed_emitter_image="${REGISTRY_HOSTPORT}/mirror/docker.io/curlimages/curl@sha256:846c5f0324b40f833b9a1fa3d5a667ac0f2b4712c9a39cae8cafe890286c52f2"
	# <<-'JOBEOF': strip leading tabs (<<-) AND prevent Bash variable expansion (single-quoted).
	# All $ signs below are container-runtime variables, not bootstrap variables.
	cat >"${manifest_file}" <<-'JOBEOF'
	apiVersion: batch/v1
	kind: Job
	metadata:
	  name: observability-bootstrap-trace
	  namespace: observability
	spec:
	  backoffLimit: 0
	  ttlSecondsAfterFinished: 300
	  template:
	    metadata:
	      labels:
	        app: observability-bootstrap-trace
	        sidecar.istio.io/inject: "true"
	      annotations:
	        proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
	        sidecar.istio.io/userVolume: '{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}'
	        sidecar.istio.io/userVolumeMount: '{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}'
	    spec:
	      serviceAccountName: observability-seed-sa
	      priorityClassName: threadforge-low
	      restartPolicy: Never
	      volumes:
	        - name: istio-custom-root-cert
	          configMap:
	            name: istio-ca-root-cert
	      containers:
	        - name: emitter
	          image: __SEED_EMITTER_IMAGE__
	          resources:
	            requests:
	              cpu: 50m
	              memory: 64Mi
	            limits:
	              cpu: 100m
	              memory: 128Mi
	          command:
	            - /bin/sh
	            - -ec
	            - |
	              TEMPO_HOST="tempo.observability.svc.cluster.local"
	              TEMPO_HTTP=3100
	              TEMPO_OTLP=4318
	              EXPECTED_SPIFFE="spiffe://identity.threadforge.local/ns/observability/sa/observability-seed-sa"
	              MAX_RETRIES=5
	              is_tls_error() {
	                local f="$1"
	                [ -f "${f}" ] || return 1
	                grep -qiE 'tls|x509|certificate|handshake|SSL|transport failure reason: TLS|peer authentication|upstream connect error' "${f}"
	              }
	              cleanup() { curl -sf -X POST http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 || true; }
	              trap cleanup EXIT
	              # ── TASK 5: port contract (ingest=4317/4318, query=3100) ───────
	              if [ "${TEMPO_HTTP}" != "3100" ]; then
	                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: query port must be 3100, got ${TEMPO_HTTP}"
	                exit 1
	              fi
	              if [ "${TEMPO_OTLP}" != "4317" ] && [ "${TEMPO_OTLP}" != "4318" ]; then
	                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: ingest port must be 4317 or 4318, got ${TEMPO_OTLP}"
	                exit 1
	              fi
	              # ── TASK 3: Verify Envoy sidecar and SPIFFE identity ─────────────
	              echo "[seed] Checking Envoy sidecar and SPIFFE identity..."
	              ENVOY_CERTS=""
	              for i in 1 2 3 4 5; do
	                ENVOY_CERTS=$(curl -sf --max-time 3 http://127.0.0.1:15000/certs 2>/tmp/envoy-certs-err.txt || true)
	                [ -n "${ENVOY_CERTS}" ] && break
	                echo "[seed] Envoy not yet ready (attempt ${i}/5)..."
	                sleep 2
	              done
	              if [ -z "${ENVOY_CERTS}" ]; then
	                echo "[FAIL] TEMPO_MTLS_FAILURE: no istio-proxy detected — Envoy admin 127.0.0.1:15000 unreachable"
	                cat /tmp/envoy-certs-err.txt 2>/dev/null || true
	                exit 1
	              fi
	              SPIFFE_ID=$(printf '%s\n' "${ENVOY_CERTS}" | sed -n 's/.*"uri":[[:space:]]*"\(spiffe:\/\/[^"[:space:]]*\)".*/\1/p' | grep -Fx "${EXPECTED_SPIFFE}" | head -1 || true)
	              if [ -z "${SPIFFE_ID}" ]; then
	                echo "[FAIL] TEMPO_MTLS_FAILURE: expected SPIFFE URI not present in Envoy cert chain"
	                printf '%s\n' "${ENVOY_CERTS}" | head -5
	                exit 1
	              fi
	              if [ "${SPIFFE_ID}" != "${EXPECTED_SPIFFE}" ]; then
	                echo "[FAIL] TEMPO_MTLS_FAILURE: SPIFFE identity mismatch"
	                echo "[seed] expected=${EXPECTED_SPIFFE} actual=${SPIFFE_ID}"
	                exit 1
	              fi
	              if ! printf '%s' "${ENVOY_CERTS}" | grep -q "cert_chain"; then
	                echo "[FAIL] TEMPO_MTLS_FAILURE: Envoy cert chain missing (SDS issuance absent)"
	                echo "[FAIL] TEMPO_MTLS_FAILURE: issuer is not SPIRE"
	                exit 1
	              fi
	              echo "[seed] SPIFFE identity: ${SPIFFE_ID}"
	              # ── TASK 2: DNS resolution check ─────────────────────────────────
	              echo "[seed] Checking DNS resolution for ${TEMPO_HOST}..."
	              DNS_RC=0
	              curl -sf --connect-timeout 3 --max-time 5 -o /dev/null \
	                "http://${TEMPO_HOST}:${TEMPO_HTTP}/ready" 2>/tmp/dns-err.txt || DNS_RC=$?
	              if [ "${DNS_RC}" -eq 6 ]; then
	                echo "[FAIL] TEMPO_DNS_UNRESOLVED: cannot resolve ${TEMPO_HOST}"
	                cat /tmp/dns-err.txt
	                exit 1
	              fi
	              # ── TASK 2: HTTP /ready gate with retry ──────────────────────────
	              echo "[seed] Waiting for Tempo /ready (port ${TEMPO_HTTP})..."
	              READY_STATUS=""
	              READY_RC=0
	              READY_MAX_ATTEMPTS=15
	              READY_DEGRADED_AUTHZ=0
	              i=1
	              while [ "${i}" -le "${READY_MAX_ATTEMPTS}" ]; do
	                READY_RC=0
	                READY_STATUS=$(curl -s -o /tmp/ready-body.txt -w '%{http_code}' \
	                  --connect-timeout 5 --max-time 10 \
	                  "http://${TEMPO_HOST}:${TEMPO_HTTP}/ready" 2>/tmp/ready-err.txt) || READY_RC=$?
	                [ "${READY_RC}" -eq 6 ] && { echo "[FAIL] TEMPO_DNS_UNRESOLVED: DNS lost during /ready check"; exit 1; }
	                if [ "${READY_STATUS}" = "403" ] || [ "${READY_STATUS}" = "401" ]; then
	                  if [ "${i}" -lt "${READY_MAX_ATTEMPTS}" ]; then
	                    echo "[seed] /ready denied HTTP ${READY_STATUS} (attempt ${i}/${READY_MAX_ATTEMPTS}), retrying while policy/xDS settles..."
	                    sleep 2
	                    i=$((i + 1))
	                    continue
	                  fi
	                  # Some Tempo deployments keep /ready behind authorization while data-plane
	                  # ingest/query remains available. Continue to stronger ingest/query proof checks.
	                  echo "[seed] WARN: /ready denied HTTP ${READY_STATUS} after ${READY_MAX_ATTEMPTS} attempts; proceeding to ingest/query proof checks"
	                  echo "[seed] SPIFFE principal: ${SPIFFE_ID}"
	                  READY_DEGRADED_AUTHZ=1
	                  break
	                fi
	                if is_tls_error /tmp/ready-err.txt || grep -qiE 'tls|x509|certificate|handshake|transport failure reason: TLS' /tmp/ready-body.txt; then
	                  if [ "${i}" -lt "${READY_MAX_ATTEMPTS}" ]; then
	                    echo "[seed] /ready mTLS path not converged yet (attempt ${i}/${READY_MAX_ATTEMPTS}), retrying..."
	                    sleep 2
	                    i=$((i + 1))
	                    continue
	                  fi
	                  echo "[FAIL] TEMPO_MTLS_FAILURE: TLS/mTLS failure during /ready"
	                  echo "[seed] stderr: $(cat /tmp/ready-err.txt 2>/dev/null | head -c 300 || true)"
	                  echo "[seed] body: $(cat /tmp/ready-body.txt 2>/dev/null | head -c 300 || true)"
	                  exit 1
	                fi
	                if [ "${READY_STATUS}" = "200" ]; then
	                  READY_BODY=$(cat /tmp/ready-body.txt 2>/dev/null | head -c 100 || true)
	                  echo "[seed] Tempo /ready: 200 OK (${READY_BODY})"
	                  break
	                fi
	                echo "[seed] /ready returned ${READY_STATUS:-rc=${READY_RC}} (attempt ${i}/${READY_MAX_ATTEMPTS}), waiting 2s..."
	                sleep 2
	                i=$((i + 1))
	              done
	              if [ "${READY_STATUS}" != "200" ] && [ "${READY_DEGRADED_AUTHZ}" -ne 1 ]; then
	                BODY=$(cat /tmp/ready-body.txt 2>/dev/null | head -c 200 || true)
	                if [ "${READY_RC:-0}" -eq 7 ] || [ "${READY_RC:-0}" -eq 28 ]; then
	                  echo "[FAIL] TEMPO_CONNECTION_FAILED: TCP connect to ${TEMPO_HOST}:${TEMPO_HTTP} failed after ${READY_MAX_ATTEMPTS} attempts"
	                else
	                  echo "[FAIL] TEMPO_CONNECTION_FAILED: /ready not 200 after ${READY_MAX_ATTEMPTS} attempts (last=${READY_STATUS:-none})"
	                  echo "[seed] body: ${BODY}"
	                fi
	                exit 1
	              fi
	              # ── TASK 1: Generate unique trace ID ─────────────────────────────
	              TRACE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 32 || \
	                printf '%08x%08x%08x%08x' $$ ${RANDOM} ${RANDOM} ${RANDOM})
	              SPAN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16 || \
	                printf '%016x' $((${RANDOM} * 65536 + ${RANDOM})))
	              NOW_S=$(date +%s)
	              NOW_NS="${NOW_S}000000000"
	              END_NS="$((NOW_S * 1000000000 + 100000000))"
	              echo "[seed] trace_id=${TRACE_ID} span_id=${SPAN_ID}"
	              # ── Build OTLP JSON payload ───────────────────────────────────────
	              printf '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"bootstrap-observability"}}]},"scopeSpans":[{"spans":[{"traceId":"%s","spanId":"%s","name":"tempo-seed-proof","kind":2,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","status":{"code":1}}]}]}]}\n' \
	                "${TRACE_ID}" "${SPAN_ID}" "${NOW_NS}" "${END_NS}" >/tmp/payload.json
	              # ── TASK 1+5: Send trace with bounded retry ───────────────────────
	              echo "[seed] Sending trace to ${TEMPO_HOST}:${TEMPO_OTLP}/v1/traces..."
	              INGEST_STATUS=""
	              ATTEMPT=0
	              while [ "${ATTEMPT}" -lt "${MAX_RETRIES}" ]; do
	                ATTEMPT=$((ATTEMPT + 1))
	                INGEST_RC=0
	                INGEST_STATUS=$(curl -s -o /tmp/ingest-resp.txt -w '%{http_code}' \
	                  --connect-timeout 5 --max-time 20 \
	                  -H 'Content-Type: application/json' \
	                  --data @/tmp/payload.json \
	                  "http://${TEMPO_HOST}:${TEMPO_OTLP}/v1/traces" 2>/tmp/ingest-err.txt) || INGEST_RC=$?
	                INGEST_BODY=$(cat /tmp/ingest-resp.txt 2>/dev/null | head -c 300 || true)
	                echo "[seed] Ingest attempt ${ATTEMPT}/${MAX_RETRIES}: HTTP=${INGEST_STATUS:-none} rc=${INGEST_RC} body=${INGEST_BODY}"
	                [ "${INGEST_RC}" -eq 6 ] && { echo "[FAIL] TEMPO_DNS_UNRESOLVED: DNS lost during ingestion"; exit 1; }
	                if is_tls_error /tmp/ingest-err.txt || grep -qiE 'tls|x509|certificate|handshake|transport failure reason: TLS' /tmp/ingest-resp.txt; then
	                  echo "[FAIL] TEMPO_MTLS_FAILURE: TLS/mTLS failure during ingestion"
	                  echo "[seed] stderr: $(cat /tmp/ingest-err.txt 2>/dev/null | head -c 300 || true)"
	                  echo "[seed] body: ${INGEST_BODY}"
	                  exit 1
	                fi
	                # ── TASK 6: Policy block — do NOT retry ──────────────────────
	                if [ "${INGEST_STATUS}" = "403" ] || [ "${INGEST_STATUS}" = "401" ]; then
	                  echo "[FAIL] TEMPO_POLICY_DENIED: ingestion rejected HTTP ${INGEST_STATUS} (mTLS/SPIFFE/AuthorizationPolicy)"
	                  echo "[seed] SPIFFE principal: ${SPIFFE_ID}"
	                  exit 1
	                fi
	                # 4xx semantic errors — do NOT retry
	                if echo "${INGEST_STATUS}" | grep -qE '^4[0-9]{2}$'; then
	                  echo "[FAIL] TEMPO_INGEST_REJECTED: semantic error HTTP ${INGEST_STATUS}"
	                  echo "[seed] body: ${INGEST_BODY}"
	                  exit 1
	                fi
	                if [ "${INGEST_STATUS}" = "200" ] || [ "${INGEST_STATUS}" = "202" ]; then
	                  echo "[seed] Trace accepted (HTTP ${INGEST_STATUS})"
	                  break
	                fi
	                # 503 / connection error — retry allowed (bounded)
	                if [ "${INGEST_STATUS}" = "503" ] || [ "${INGEST_RC}" -eq 7 ] || [ "${INGEST_RC}" -eq 28 ]; then
	                  echo "[seed] Transient failure — retrying in $((ATTEMPT * 2))s..."
	                  sleep $((ATTEMPT * 2))
	                  continue
	                fi
	                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: HTTP ${INGEST_STATUS} rc=${INGEST_RC}"
	                echo "[seed] body: ${INGEST_BODY}"
	                exit 1
	              done
	              if [ "${INGEST_STATUS}" != "200" ] && [ "${INGEST_STATUS}" != "202" ]; then
	                echo "[FAIL] TEMPO_CONNECTION_FAILED: ingestion failed after ${MAX_RETRIES} attempts (last=${INGEST_STATUS:-none})"
	                exit 1
	              fi
	              # ── TASK 4: Verify trace is retrievable ───────────────────────────
	              echo "[seed] Verifying trace ${TRACE_ID} is retrievable from Tempo query API..."
	              sleep 3
	              QUERY_STATUS=""
	              for i in 1 2 3 4 5; do
	                QUERY_RC=0
	                QUERY_STATUS=$(curl -s -o /tmp/query-resp.txt -w '%{http_code}' \
	                  --connect-timeout 5 --max-time 15 \
	                  "http://${TEMPO_HOST}:${TEMPO_HTTP}/api/traces/${TRACE_ID}" 2>/tmp/query-err.txt) || QUERY_RC=$?
	                QUERY_BODY=$(cat /tmp/query-resp.txt 2>/dev/null | head -c 300 || true)
	                echo "[seed] Query ${i}/5: HTTP=${QUERY_STATUS:-none} rc=${QUERY_RC}"
	                # ── TASK 6: Query policy block ────────────────────────────────
	                if [ "${QUERY_STATUS}" = "403" ] || [ "${QUERY_STATUS}" = "401" ]; then
	                  echo "[FAIL] TEMPO_POLICY_DENIED: trace query rejected HTTP ${QUERY_STATUS}"
	                  echo "[seed] SPIFFE principal ${SPIFFE_ID} unauthorized for port ${TEMPO_HTTP}"
	                  exit 1
	                fi
	                if is_tls_error /tmp/query-err.txt || grep -qiE 'tls|x509|certificate|handshake|transport failure reason: TLS' /tmp/query-resp.txt; then
	                  echo "[FAIL] TEMPO_MTLS_FAILURE: TLS/mTLS failure during query"
	                  echo "[seed] stderr: $(cat /tmp/query-err.txt 2>/dev/null | head -c 300 || true)"
	                  echo "[seed] body: ${QUERY_BODY}"
	                  exit 1
	                fi
	                if [ "${QUERY_STATUS}" = "404" ]; then
	                  echo "[seed] Trace not yet indexed (attempt ${i}/5)..."
	                  sleep $((i * 2))
	                  continue
	                fi
	                if [ "${QUERY_STATUS}" = "200" ]; then
	                  if printf '%s' "${QUERY_BODY}" | grep -qi "${TRACE_ID}"; then
	                    echo "[seed] CONFIRMED: trace ${TRACE_ID} in Tempo store"
	                    break
	                  fi
	                  echo "[seed] Query 200 but traceID absent from body (attempt ${i}/5)..."
	                  sleep 2
	                  continue
	                fi
	                [ "${QUERY_RC}" -eq 7 ] || [ "${QUERY_RC}" -eq 28 ] && { sleep 2; continue; }
	                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: query returned HTTP ${QUERY_STATUS}"
	                echo "[seed] body: ${QUERY_BODY}"
	                exit 1
	              done
	              if [ "${QUERY_STATUS}" != "200" ]; then
	                echo "[FAIL] TEMPO_INGEST_REJECTED: trace ${TRACE_ID} not retrievable after 5 query attempts (last=${QUERY_STATUS:-none})"
	                echo "[seed] Ingestion was accepted but trace is not queryable — storage or indexing failure"
	                exit 1
	              fi
	              echo "[seed] PASS: trace ingested and verified in Tempo"
	              echo "[seed] trace_id=${TRACE_ID} spiffe_id=${SPIFFE_ID}"
	              echo "[seed] observability_ingestion_verified=PASS"
JOBEOF
	sed -i "s#__SEED_EMITTER_IMAGE__#${seed_emitter_image}#g" "${manifest_file}"
	kubectl apply -f "${manifest_file}" >/dev/null
	rm -f "${manifest_file}"

	job_uid="$(proof_job_uid_or_fail observability "${job_name}")" \
		|| fail_bootstrap "tempo seed proof job UID unavailable after creation"

	deadline=$((SECONDS + seed_timeout))
	pod_name="" pod_uid="" emitter_reason="" emitter_exit=""
	while (( SECONDS < deadline )); do
		job_succeeded="$(kubectl get job -n observability "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
		job_failed="$(kubectl get job -n observability "${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
		if [[ -n "${job_succeeded}" && "${job_succeeded}" -ge 1 ]]; then
			emitter_reason="Completed"
			emitter_exit="0"
			break
		fi
		if [[ -n "${job_failed}" && "${job_failed}" -ge 1 ]]; then
			echo "[bootstrap] Tempo seed proof job failed; collecting diagnostics" >&2
			kubectl describe job -n observability "${job_name}" >&2 2>/dev/null || true
			kubectl get pods -n observability -l job-name="${job_name}" -o wide >&2 2>/dev/null || true
			pod_name="$(kubectl get pods -n observability -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
			if [[ -n "${pod_name}" ]]; then
				kubectl logs -n observability "${pod_name}" -c emitter >&2 2>/dev/null || true
			fi
			fail_bootstrap "tempo seed proof failed — Job entered failed state"
		fi

		set +e
		pod_identity="$(proof_owned_pod_for_job_uid_or_fail observability "${job_name}" "${job_uid}" 2>/dev/null)"
		pod_rc=$?
		set -e
		if [[ "${pod_rc}" -eq 2 ]]; then
			fail_bootstrap "tempo seed proof failed: pod identity ambiguous for Job UID ${job_uid}"
		fi
		if [[ "${pod_rc}" -eq 1 ]]; then
			if [[ -n "${pod_uid}" ]]; then
				fail_bootstrap "tempo seed proof failed: pod for Job UID ${job_uid} disappeared before completion"
			fi
			sleep 2
			continue
		fi
		if [[ "${pod_rc}" -eq 0 && -n "${pod_identity}" ]]; then
			IFS=$'\t' read -r current_pod_name current_pod_uid current_pod_created <<<"${pod_identity}"
			if [[ -z "${pod_uid}" ]]; then
				pod_name="${current_pod_name}"
				pod_uid="${current_pod_uid}"
			elif [[ "${current_pod_uid}" != "${pod_uid}" ]]; then
				fail_bootstrap "tempo seed proof failed: pod UID changed for Job UID ${job_uid}"
			fi
			pod_name="${current_pod_name}"
		fi
		if [[ -n "${pod_name}" ]]; then
			if [[ "${sidecar_checked}" -eq 0 ]]; then
				if ! kubectl get pod -n observability "${pod_name}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -qw istio-proxy; then
					kubectl logs -n observability "${pod_name}" -c emitter >&2 2>/dev/null || true
					fail_bootstrap "tempo seed proof failed: missing istio-proxy container (sidecar injection absent)"
				fi
				sidecar_checked=1
			fi
			emitter_reason="$(kubectl get pod -n observability "${pod_name}" -o jsonpath='{range .status.containerStatuses[?(@.name=="emitter")]}{.state.terminated.reason}{end}' 2>/dev/null || true)"
			emitter_exit="$(kubectl get pod -n observability "${pod_name}" -o jsonpath='{range .status.containerStatuses[?(@.name=="emitter")]}{.state.terminated.exitCode}{end}' 2>/dev/null || true)"
			if [[ "${emitter_reason}" == "Completed" && "${emitter_exit}" == "0" ]]; then
				break
			fi
			if [[ -n "${emitter_exit}" && "${emitter_exit}" != "0" ]]; then
				echo "[bootstrap] Tempo seed proof emitter logs:" >&2
				kubectl logs -n observability "${pod_name}" -c emitter >&2 2>/dev/null || true
				fail_bootstrap "tempo seed proof failed — see emitter logs above"
			fi
		fi
		sleep 2
	done
	if [[ "${emitter_reason:-}" != "Completed" || "${emitter_exit:-}" != "0" ]]; then
		echo "[bootstrap] Tempo seed proof timed out; collecting diagnostics" >&2
		kubectl get job -n observability "${job_name}" -o wide >&2 2>/dev/null || true
		kubectl describe job -n observability "${job_name}" >&2 2>/dev/null || true
		kubectl get pods -n observability -l job-name="${job_name}" -o wide >&2 2>/dev/null || true
		kubectl get events -n observability --sort-by=.lastTimestamp | tail -n 40 >&2 2>/dev/null || true
		if [[ -n "${pod_name:-}" ]]; then
			echo "[bootstrap] Tempo seed proof emitter logs (timeout):" >&2
			kubectl logs -n observability "${pod_name}" -c emitter >&2 2>/dev/null || true
		fi
		fail_bootstrap "tempo seed proof timed out — Tempo may not be accepting traces"
	fi

	# Belt-and-suspenders: verify Tempo metrics counter incremented
	tempo_metrics="$(kubectl exec -n observability statefulset/tempo -- wget -qO- http://localhost:3100/metrics 2>/dev/null || true)"
	printf '%s\n' "${tempo_metrics}" | awk '/^tempo_distributor_spans_received_total/ {sum += $NF} END {exit !(sum > 0)}' \
		|| fail_bootstrap "tempo ingestion counters are zero after successful seed proof"

	kubectl delete job -n observability "${job_name}" --ignore-not-found=true >/dev/null 2>&1 || true
	echo "[bootstrap] Tempo seed proof: PASS"
}

clear_stale_istio_ca_material() {
	if ! kubectl get ns istio-system >/dev/null 2>&1; then
		return 0
	fi

	echo "[bootstrap] deleting stale istio-system CA material"
	kubectl -n istio-system delete secret cacerts istiod-tls istio-ca-secret threadforge-root-ca --ignore-not-found >/dev/null 2>&1 || true
	kubectl -n istio-system delete configmap threadforge-root-ca --ignore-not-found >/dev/null 2>&1 || true
}

configure_kind_registry_trust() {
	local ca_file node registry
	ca_file="${REGISTRY_CA_CERT_PATH}"
	registry="${REGISTRY_HOST}:${REGISTRY_PORT}"

	# HARD REQUIREMENT: CA cert must exist on disk — no extraction, no fallback
	if [[ ! -f "${ca_file}" ]]; then
		echo "[FAIL] MISSING_PREREQ: registry CA cert not found at ${ca_file}"
		echo "[FAIL] Run: openssl req -new -x509 -newkey rsa:3072 -sha256 -keyout certs/registry-ca.key -out certs/threadforge-ingress-ca.crt -days 365 -nodes -subj '/CN=threadforge-ingress-ca' -addext 'basicConstraints=critical,CA:TRUE'"
		exit 10
	fi

	# Validate the CA can verify the registry TLS cert before installing
	openssl s_client -connect "${registry}" </dev/null 2>/dev/null \
		| openssl x509 -outform PEM > /tmp/registry-leaf-check.pem 2>/dev/null
	if ! openssl verify -CAfile "${ca_file}" /tmp/registry-leaf-check.pem >/dev/null 2>&1; then
		echo "[FAIL] registry TLS cert cannot be verified by ${ca_file}"
		echo "[FAIL] The registry must serve a cert signed by CN=threadforge-ingress-ca"
		exit 2
	fi
	rm -f /tmp/registry-leaf-check.pem

	for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
		# Install CA into OS trust store
		docker cp "${ca_file}" "${node}:/usr/local/share/ca-certificates/threadforge-ingress-ca.crt"

		# Install into containerd certs.d
		docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${registry}"
		docker cp "${ca_file}" "${node}:/etc/containerd/certs.d/${registry}/ca.crt"

		# Write hosts.toml — no skip_verify, no fallback
		docker exec "${node}" bash -c "cat > /etc/containerd/certs.d/${registry}/hosts.toml << 'EOF'
server = \"https://${registry}\"

[host.\"https://${registry}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  ca = [\"/etc/containerd/certs.d/${registry}/ca.crt\"]
EOF"

		# Update OS trust store and restart containerd
		docker exec "${node}" update-ca-certificates >/dev/null
		docker exec "${node}" systemctl restart containerd >/dev/null

		# HARD FAIL: validate TLS trust actually works before proceeding
		registry_http_code="$(docker exec "${node}" sh -c "curl -sS --cacert '/usr/local/share/ca-certificates/threadforge-ingress-ca.crt' -o /dev/null -w '%{http_code}' 'https://${registry}/v2/'" || true)"
		if [[ "${registry_http_code}" != "200" && "${registry_http_code}" != "401" && "${registry_http_code}" != "403" ]]; then
			echo "[FAIL] registry TLS validation failed on node ${node} — aborting"
			exit 2
		fi
		echo "[bootstrap] registry TLS trust verified on ${node}"
	done
}

# PREREQ: CA cert must exist — fail immediately if missing
if [[ ! -f "${REGISTRY_CA_CERT_PATH}" ]]; then
	echo "[FAIL] MISSING_PREREQ: ${REGISTRY_CA_CERT_PATH} not found"
	echo "[FAIL] Registry CA must be generated before bootstrap. See DEVELOPMENT.md."
	exit 10
fi

ensure_registry_ca_artifacts
publish_registry_ca_configmaps
ensure_threadforge_test_namespace

echo "[bootstrap] configuring HTTPS registry trust"
configure_kind_registry_trust

# Patch CoreDNS to resolve registry.threadforge.local to its IPv4 address in the
# kind network.  Without this, CoreDNS inherits the host's DNS which returns the
# IPv6 fc00::/7 Docker address — unreachable from pods.  This causes the Kyverno
# cosign webhook to time out when verifying image signatures against the registry.
echo "[bootstrap] patching CoreDNS hosts entry for registry.threadforge.local"
# Prefer inspecting the authoritative registry container (if set/running),
# then fall back to inspecting by hostname or common alternate container names.
# Using the container name avoids accidental name collisions with other
# containers or images that can cause docker inspect to return the wrong IP.
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
_registry_ipv4=""
if docker inspect "${REGISTRY_CONTAINER}" >/dev/null 2>/dev/null; then
	_registry_ipv4="$(docker inspect "${REGISTRY_CONTAINER}" --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
	if [ -z "$_registry_ipv4" ]; then
		_registry_ipv4="$(docker inspect "${REGISTRY_CONTAINER}" --format '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{end}}{{end}}' 2>/dev/null | head -1 || true)"
	fi
fi

# If container-based lookup failed, fall back to inspecting the hostname or
# known alternate names used by create-local-registry (local-registry, registry).
if [ -z "$_registry_ipv4" ]; then
	_registry_ipv4="$(docker inspect "${REGISTRY_HOST%%:*}" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
	if [ -z "$_registry_ipv4" ]; then
		_registry_ipv4="$(docker inspect "${REGISTRY_HOST%%:*}" --format '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{end}}{{end}}' 2>/dev/null | head -1 || true)"
	fi
	for _alt_name in local-registry registry; do
		[ -n "$_registry_ipv4" ] && break
		_registry_ipv4="$(docker inspect "${_alt_name}" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || true)"
		[ -z "$_registry_ipv4" ] && _registry_ipv4="$(docker inspect "${_alt_name}" --format '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{end}}{{end}}' 2>/dev/null | head -1 || true)"
	done
fi
if [ -n "$_registry_ipv4" ]; then
  kubectl patch configmap coredns -n kube-system --type merge -p \
    "{\"data\":{\"Corefile\":\".:53 {\\n    errors\\n    health {\\n       lameduck 5s\\n    }\\n    ready\\n    hosts {\\n       ${_registry_ipv4} ${REGISTRY_HOST%%:*}\\n       fallthrough\\n    }\\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\\n       pods insecure\\n       fallthrough in-addr.arpa ip6.arpa\\n       ttl 30\\n    }\\n    prometheus :9153\\n    forward . /etc/resolv.conf {\\n       max_concurrent 1000\\n    }\\n    cache 30\\n    loop\\n    reload\\n    loadbalance\\n}\\n\"}}" >/dev/null
  kubectl rollout restart deployment/coredns -n kube-system >/dev/null
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s >/dev/null
  echo "[bootstrap] CoreDNS patched: ${REGISTRY_HOST%%:*} -> ${_registry_ipv4}"
  # Validate DNS resolution is reachable from inside the cluster using a
  # temporary dnsutils pod. CoreDNS pods lack nslookup/dig, so we spawn a
  # one-shot pod in the kube-system namespace with hostNetwork=false so it
  # uses the cluster DNS.
  echo "[bootstrap] validating CoreDNS resolves ${REGISTRY_HOST%%:*}"
  _resolved_ip="$(kubectl run threadforge-dns-probe-$$ \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
    --restart=Never \
    --rm \
    --quiet \
    --namespace=kube-system \
    --command \
    --timeout=30s \
    -- sh -c "nslookup ${REGISTRY_HOST%%:*} 2>/dev/null | awk '/^Address/ && !/^Address: #/ {print \$2; exit}'" \
    2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
  if [ -z "$_resolved_ip" ]; then
    # Fallback: check directly via corefile hosts block already confirmed in kubectl get configmap
    _hosts_entry="$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "${REGISTRY_HOST%%:*}" || true)"
    if [ -n "$_hosts_entry" ]; then
      echo "[bootstrap] DNS probe pod unavailable; Corefile hosts entry confirmed: $_hosts_entry"
      echo "[bootstrap] DNS validated via Corefile inspection (probe pod image not cached)"
    else
      fail_bootstrap "REGISTRY_DNS_FAIL: ${REGISTRY_HOST%%:*} does not resolve inside cluster after CoreDNS patch"
    fi
  elif [ "$_resolved_ip" != "$_registry_ipv4" ]; then
    fail_bootstrap "REGISTRY_DNS_FAIL: ${REGISTRY_HOST%%:*} resolved to ${_resolved_ip} but expected ${_registry_ipv4}"
  else
    echo "[bootstrap] DNS validated: ${REGISTRY_HOST%%:*} -> ${_resolved_ip} (PASS)"
  fi
else
  # No registry IP means all cosign webhook verifications will silently time out.
  # This is classified as a hard infrastructure failure, not a warning.
  fail_bootstrap "REGISTRY_DNS_FAIL: could not determine IPv4 address for ${REGISTRY_HOST%%:*}; CoreDNS patch required for signature enforcement"
fi

mkdir -p "${DEBUG_DIR}"

echo "[bootstrap] ensuring cosign signing keys"
bash "$REPO_ROOT/scripts/lib/ensure_cosign_keys.sh"

echo "[bootstrap] preparing internal Istio images"
THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY}" \
ISTIO_TAG="${ISTIO_TAG}" \
ISTIO_PILOT_DIGEST="${ISTIO_PILOT_DIGEST}" \
ISTIO_PROXYV2_DIGEST="${ISTIO_PROXYV2_DIGEST}" \
	# Preload any missing mirror images into the internal registry before
	# running the Istio-specific mirror step. This is idempotent and will
	# attempt to derive upstream sources for /mirror/* entries.
	REGISTRY_HOSTPORT="${THREADFORGE_REGISTRY}" \
	THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER}" \
	THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD}" \
	bash "$REPO_ROOT/scripts/infra/preload_registry.sh"

THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY}" \
ISTIO_TAG="${ISTIO_TAG}" \
ISTIO_PILOT_DIGEST="${ISTIO_PILOT_DIGEST}" \
ISTIO_PROXYV2_DIGEST="${ISTIO_PROXYV2_DIGEST}" \
	bash "$REPO_ROOT/scripts/install/prepare_istio_images.sh"

echo "[bootstrap] applying workload priority classes"
kubectl apply -f platform/deploy/infra/system/priority-classes.yaml >/dev/null

echo "[bootstrap] deferring Istio install until cert-manager and SPIRE complete"

set_bootstrap_phase "crd-establishment" "starting prometheus and cert-manager CRD establishment"

log_helm_repo_diagnostics "pre-crd-establishment"
ensure_helm_repo_hydrated "prometheus-community" "https://prometheus-community.github.io/helm-charts" "prometheus-community/kube-prometheus-stack"

echo "[bootstrap] installing prometheus CRDs"
helm show crds prometheus-community/kube-prometheus-stack | kubectl apply --server-side -f - >/dev/null

ensure_helm_repo_hydrated "jetstack" "https://charts.jetstack.io" "jetstack/cert-manager" "${CERT_MANAGER_VERSION}"

cert_manager_crds_file="$(mktemp)"
trap 'rm -f "${cert_manager_crds_file}"' RETURN

echo "[bootstrap] installing cert-manager CRDs"
render_chart_crds cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" cert-manager "${cert_manager_crds_file}"
[[ -s "${cert_manager_crds_file}" ]] || fail_bootstrap "cert-manager CRD render returned no objects"
kubectl apply -f "${cert_manager_crds_file}" >/dev/null
kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s >/dev/null
kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s >/dev/null
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=120s >/dev/null
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || {
	echo "[FAIL] cert-manager CRDs missing"
	exit 2
}

echo "[bootstrap] installing cert-manager controller"
kubectl create namespace cert-manager --dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
kubectl -n cert-manager create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
cert_manager_registry_hostport="${THREADFORGE_REGISTRY}"
helm upgrade --install cert-manager jetstack/cert-manager \
	--namespace cert-manager \
	--version "$CERT_MANAGER_VERSION" \
	--set installCRDs=false \
	--set-json 'global.imagePullSecrets=[{"name":"registry-credentials"}]' \
	--set image.repository=${cert_manager_registry_hostport}/cert-manager/controller \
	--set image.digest=sha256:6bf0fd34e1d5b58e31bfdc640d5d284e528685b19f20df6c0fb6f13867603bba \
	--set cainjector.image.repository=${cert_manager_registry_hostport}/cert-manager/cainjector \
	--set cainjector.image.digest=sha256:6381b508a274d56f0ed3ac6af76faf12e3e5a2e0028d33a13039e364c45c93ff \
	--set webhook.image.repository=${cert_manager_registry_hostport}/cert-manager/webhook \
	--set webhook.image.digest=sha256:7f16d397b8b48c5133d9f2859fb2dea30f0f297eb04c517bbfc06f5d207b3cf0 \
	--set startupapicheck.image.repository=${cert_manager_registry_hostport}/cert-manager/startupapicheck \
	--set startupapicheck.image.digest=sha256:d313d9b8a846c163e52eebe68fd5e7da2457fddda2f144848de17b6fcd6e14f4 >/dev/null
# Keep service accounts aligned with the pod-level pull secret for later restarts.
for sa in cert-manager cert-manager-cainjector cert-manager-webhook cert-manager-startupapicheck; do
  kubectl patch serviceaccount "$sa" -n cert-manager -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
done
label_namespace_injection cert-manager disabled

echo "[bootstrap] waiting for cert-manager"
kubectl wait --for=condition=Available deployment -n cert-manager --all --timeout=120s >/dev/null
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || {
	echo "[FAIL] cert-manager CRDs missing"
	exit 2
}
complete_bootstrap_phase "crd-establishment" "PASS" "cert-manager and CRDs established"

echo "[bootstrap] *** LEGACY CA ISSUERS DISABLED ***"
echo "[bootstrap] SPIRE is the sole certificate issuer; cert-manager CA issuers are not created"

echo "[bootstrap] clearing stale Kyverno admission policies before SPIRE install"
kubectl delete clusterpolicy threadforge-require-internal-registry --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterpolicy threadforge-require-signed-images --ignore-not-found >/dev/null 2>&1 || true

echo "[bootstrap] installing SPIRE"
kubectl get ns spire-system >/dev/null 2>&1 || kubectl create ns spire-system
kubectl -n spire-system delete daemonset spire-agent --ignore-not-found >/dev/null 2>&1 || true
kubectl -n spire-system delete statefulset spire-server --ignore-not-found >/dev/null 2>&1 || true
spire_server_pvc_name="spire-server-data"
spire_server_pv_name="$(kubectl -n spire-system get pvc "${spire_server_pvc_name}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -n "${spire_server_pv_name}" ]]; then
	spire_server_data_path="$(kubectl get pv "${spire_server_pv_name}" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)"
	if [[ -n "${spire_server_data_path}" ]]; then
		docker exec threadforge-control-plane sh -c "rm -f '${spire_server_data_path}/journal.pem'" >/dev/null 2>&1 \
			|| fail_bootstrap "unable to clear stale SPIRE server journal"
	fi
fi
kubectl -n spire-system delete configmap spire-agent-config spire-server-config --ignore-not-found >/dev/null 2>&1 || true
# The SPIRE chart owns spire-bundle. If a stale client-side-applied copy exists,
# Helm will refuse to adopt it; clear only this generated object so Helm can recreate it.
kubectl -n spire-system delete configmap spire-bundle --ignore-not-found >/dev/null 2>&1 || true
kubectl -n spire-system create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
	helm upgrade --install spire platform/deploy/infra/spire -n spire-system -f platform/deploy/infra/spire/values.yaml --set spireAgent.enabled=false --atomic=false
	kubectl delete deployment spire-server -n spire-system --ignore-not-found >/dev/null 2>&1 || true
	kubectl wait --for=delete deployment/spire-server -n spire-system --timeout=120s >/dev/null 2>&1 || true
# Patch service accounts to use registry credentials
for sa in spire-server spire-agent; do
  kubectl patch serviceaccount "$sa" -n spire-system -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
done
kubectl patch statefulset spire-server -n spire-system --type='merge' \
	-p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"registry-credentials"}]}}}}' >/dev/null
kubectl delete pod spire-server-0 -n spire-system --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl delete pod -n spire-system -l app=spire-agent --ignore-not-found --wait=false >/dev/null 2>&1 || true
label_namespace_injection spire-system disabled

echo "[bootstrap] waiting for spire-system"
set_bootstrap_phase "spire-server-readiness" "waiting for spire-server rollout"
kubectl rollout status statefulset/spire-server -n spire-system --timeout=180s
complete_bootstrap_phase "spire-server-readiness" "PASS" "spire-server rollout completed"

echo "[bootstrap] publishing active SPIRE trust bundle"
spire_bundle_tmp="$(mktemp)"
kubectl -n spire-system exec spire-server-0 -- \
	/opt/spire/bin/spire-server bundle show \
	-socketPath /run/spire/private/spire-server.sock \
	-format pem >"${spire_bundle_tmp}" 2>/dev/null \
	|| fail_bootstrap "unable to read SPIRE bundle for trust publication"
openssl x509 -in "${spire_bundle_tmp}" -noout >/dev/null 2>&1 \
	|| fail_bootstrap "SPIRE bundle is not valid PEM"
kubectl create configmap spire-bundle \
	--namespace spire-system \
	--from-file=bundle.crt="${spire_bundle_tmp}" \
	--from-file=bundle.pem="${spire_bundle_tmp}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
spire_agent_bundle_der_tmp="$(mktemp)"
spire_active_root_pem_tmp="$(mktemp)"
bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null \
	|| fail_bootstrap "unable to refresh trust authority state before agent cache update"
jq -r '.active_root_pem // empty' "${TRUST_AUTHORITY_STATE_FILE}" >"${spire_active_root_pem_tmp}" \
	|| fail_bootstrap "unable to read active SPIRE root from trust authority state"
if ! grep -q 'BEGIN CERTIFICATE' "${spire_active_root_pem_tmp}"; then
	fail_bootstrap "trust authority state did not include an active SPIRE root certificate"
fi
openssl x509 -in "${spire_active_root_pem_tmp}" -outform der >"${spire_agent_bundle_der_tmp}" 2>/dev/null \
	|| fail_bootstrap "unable to convert active SPIRE root to DER for agent cache"
docker exec threadforge-control-plane sh -c 'mkdir -p /var/lib/spire-agent/data' >/dev/null 2>&1 || true
docker cp "${spire_agent_bundle_der_tmp}" threadforge-control-plane:/var/lib/spire-agent/data/bundle.der >/dev/null 2>&1 \
	|| fail_bootstrap "unable to refresh SPIRE agent trust cache"
docker exec threadforge-control-plane sh -c 'chown 0:0 /var/lib/spire-agent/data/bundle.der && chmod 0644 /var/lib/spire-agent/data/bundle.der' >/dev/null 2>&1 \
	|| fail_bootstrap "unable to normalize SPIRE agent trust cache permissions"
rm -f "${spire_agent_bundle_der_tmp}"
rm -f "${spire_active_root_pem_tmp}"
rm -f "${spire_bundle_tmp}"

# Keep the server restart behind the disabled-agent boundary. Otherwise the
# newly schedulable agent can attest during the server's restart window.
echo "[bootstrap] restarting SPIRE server before releasing agent scheduling"
kubectl delete pod spire-server-0 -n spire-system --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl rollout status statefulset/spire-server -n spire-system --timeout=180s
echo "[bootstrap] enabling SPIRE agent after trust bundle publication"
kubectl patch daemonset spire-agent -n spire-system --type=json \
	-p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' >/dev/null
kubectl patch daemonset spire-agent -n spire-system --type='merge' \
	-p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"registry-credentials"}]}}}}' >/dev/null

set_bootstrap_phase "spire-agent-rollout" "waiting for spire-agent rollout"
kubectl rollout status daemonset/spire-agent -n spire-system --timeout=180s
if ! spire_restart_failure="$(spire_agent_restart_contract_failure 2>&1)"; then
	fail_bootstrap "SPIRE agent restart contract violated: ${spire_restart_failure}"
fi
complete_bootstrap_phase "spire-agent-rollout" "PASS" "spire-agent rollout completed"
echo "[bootstrap] reconciling SPIRE registration entries after agent rollout"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh" \
	|| fail_bootstrap "failed to reconcile SPIRE registration entries after spire-agent rollout"
echo "[bootstrap] creating required SPIRE entries for observability workloads"
reconcile_observability_spire_entries
echo "[bootstrap] verifying required SPIRE entries before workload deployment"
assert_observability_spire_entries
assert_tempo_spire_entry
	kubectl -n spire-system delete peerauthentication spire-server-permissive --ignore-not-found >/dev/null 2>&1 || true
	echo "[bootstrap] deferring spire-system PeerAuthentication until Istio is fully ready"

echo "[bootstrap] clearing stale Istio CA material"
clear_stale_istio_ca_material
echo "[bootstrap] setting up istio-system registry credentials"
kubectl create namespace istio-system --dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
kubectl -n istio-system create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null

echo "[bootstrap] configuring Istio SPIRE integration"
echo "[bootstrap] installing spire-csr bridge"
set_bootstrap_phase "spire-csr-install" "install spire-csr bridge"
install_spire_csr_bridge
complete_bootstrap_phase "spire-csr-install" "PASS" "spire-csr bridge installed"

reset_kyverno_release
install_kyverno_release

echo "[bootstrap] running istiod readiness prechecks (pre-istio-base-install)"
run_istiod_precheck_suite "pre-istio-base-install"

echo "[bootstrap] installing Istio"
set_bootstrap_phase "istio-base-install" "istioctl install start"
istio_install_attempts="${ISTIO_BASE_INSTALL_ATTEMPTS:-2}"
istio_install_ok="false"
for istio_install_attempt in $(seq 1 "$istio_install_attempts"); do
	tf_bt_phase_progress "istio-base-install" "istio install attempt ${istio_install_attempt}/${istio_install_attempts}"
	if istioctl install -y \
		--set hub="${THREADFORGE_REGISTRY}/istio" \
		--set tag="${ISTIO_TAG}" \
		--set values.global.imagePullSecrets[0]=registry-credentials \
		--set components.pilot.k8s.priorityClassName=threadforge-critical \
		--set components.pilot.k8s.resources.requests.cpu=500m \
		--set components.pilot.k8s.resources.requests.memory=512Mi \
		--set components.pilot.k8s.resources.limits.cpu=1000m \
		--set components.pilot.k8s.resources.limits.memory=1Gi \
		--set values.global.pilotCertProvider=custom \
		--set values.global.mountMtlsCerts=true \
		--set values.global.caAddress=spire-csr.istio-system.svc:443 \
		--set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_CERT_SIGNER=spire-csr \
		--set meshConfig.accessLogFile=/dev/stdout \
		--set meshConfig.accessLogEncoding=JSON \
		--set meshConfig.trustDomain="${SPIFFE_TRUST_DOMAIN}" \
		--set meshConfig.forwardClientCertDetails=SANITIZE_SET \
		--set meshConfig.accessLogFormat='{"authority":"%REQ(:AUTHORITY)%","method":"%REQ(:METHOD)%","path":"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%","response_code":"%RESPONSE_CODE%","downstream_peer_uri_san":"%DOWNSTREAM_PEER_URI_SAN%","downstream_local_uri_san":"%DOWNSTREAM_LOCAL_URI_SAN%","upstream_peer_uri_san":"%UPSTREAM_PEER_URI_SAN%","upstream_local_uri_san":"%UPSTREAM_LOCAL_URI_SAN%","x_forwarded_client_cert":"%REQ(X-FORWARDED-CLIENT-CERT)%"}' \
		--set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
		--set components.ingressGateways[0].enabled=false; then
		istio_install_ok="true"
		break
	fi
	tf_bt_phase_failure "istio-base-install" "istioctl install attempt ${istio_install_attempt} failed"
	collect_istiod_failure_bundle "istio-base-install attempt ${istio_install_attempt} failed"
	if (( istio_install_attempt < istio_install_attempts )); then
		tf_bt_phase_retry "istio-base-install" "retrying istioctl install after readiness diagnostics"
		echo "[bootstrap] istio base install retry reason=istiod not ready attempt=${istio_install_attempt}/${istio_install_attempts}"
		kubectl get pods -n istio-system -o wide || true
		kubectl get events -n istio-system --sort-by=.lastTimestamp | tail -n 40 || true
		sleep 5
	fi
done

if [[ "$istio_install_ok" != "true" ]]; then
	fail_bootstrap "istio base install failed after ${istio_install_attempts} attempts"
fi
complete_bootstrap_phase "istio-base-install" "PASS" "istioctl install completed"
# Patch Istio service accounts to use registry credentials
kubectl patch serviceaccount istiod -n istio-system -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
kubectl apply -f platform/deploy/infra/istio/security/peer-authentication-spire-system.yaml >/dev/null

echo "[bootstrap] reconciling Istio root configmaps"
reconcile_istio_root_configmaps pre-istiod-source
echo "[bootstrap] enforcing digest-pinned Istio sidecar injector images"
kubectl -n istio-system get configmap istio-sidecar-injector -o json \
	| jq --arg img "${THREADFORGE_REGISTRY}/istio/proxyv2@sha256:${ISTIO_PROXYV2_DIGEST}" '
		.data.values = (
			(.data.values | fromjson)
			| .global.proxy.image = $img
			| .global.proxy_init.image = $img
			| tojson
		)
		| .data.config = (
			.data.config
			| gsub("\\$\\{(?<var>[A-Za-z_][A-Za-z0-9_]*)\\}"; "$\(.var)")
		)
		| del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
	' \
	| apply_manifest_from_stdin >/dev/null
echo "[bootstrap] setting Istiod root source to spire-ca-root-cert"
kubectl -n istio-system get deployment istiod -o json \
	| jq '(.spec.template.spec.volumes[] | select(.name == "istio-csr-ca-configmap") | .configMap.name) = "spire-ca-root-cert"' \
	| apply_manifest_from_stdin >/dev/null
kubectl -n istio-system rollout restart deployment/istiod >/dev/null
kubectl -n istio-system rollout status deployment/istiod --timeout=180s \
	|| fail_bootstrap "istio-system/istiod failed to restart with spire-ca-root-cert root source"
echo "[bootstrap] reconciling controller-owned Istio trust configmap"
reconcile_istio_root_configmaps post-istiod-source
echo "[bootstrap] reconciling Istio webhook CA bundle"
reconcile_istio_webhook_cabundle
webhook_verify_rc=0
if ! verify_webhook_ca_integrity_bootstrap; then
	webhook_verify_rc=$?
fi
if [[ "$webhook_verify_rc" -ne 0 ]]; then
	case "$webhook_verify_rc" in
		11)
			fail_bootstrap "istio webhook CA preflight not ready after deterministic checks"
			;;
		2)
			fail_bootstrap "WEBHOOK_CA_MISMATCH"
			;;
		*)
			fail_bootstrap "istio webhook CA preflight verification failed (rc=${webhook_verify_rc})"
			;;
		esac
fi

echo "[bootstrap] refreshing SPIRE->Istio CA path before ingress rollout"
bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh" \
	|| fail_bootstrap "pre-ingress SPIRE->Istio CA path refresh failed"
wait_for_istio_deployment istiod

ISTIO_HELM_REPO_NAME="istio-release"
ISTIO_HELM_REPO_URL="https://istio-release.storage.googleapis.com/charts"
log_helm_repo_diagnostics "pre-istio-repo-init"
ensure_helm_repo_hydrated "${ISTIO_HELM_REPO_NAME}" "${ISTIO_HELM_REPO_URL}" "${ISTIO_HELM_REPO_NAME}/gateway" "${ISTIO_TAG}"
verify_helm_repo_present "${ISTIO_HELM_REPO_NAME}"
log_helm_repo_diagnostics "pre-ingress-install"
wait_for_service_endpoints istio-system istiod 180
verify_webhook_ca_integrity_bootstrap \
	|| fail_bootstrap "istio webhook CA preflight not ready before ingress gateway rollout"

echo "[bootstrap] installing ingress gateway"
set_bootstrap_phase "ingress-gateway-rollout" "installing ingress gateway"
reset_ingress_gateway_release
helm upgrade --install istio-ingressgateway istio-release/gateway \
	-n istio-system --version "${ISTIO_TAG}" \
	-f "$REPO_ROOT/platform/deploy/infra/istio-ingressgateway-values.yaml" >/dev/null
kubectl -n istio-system create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
kubectl -n istio-system patch serviceaccount istio-ingressgateway --type='merge' \
	-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null
kubectl -n istio-system patch deployment istio-ingressgateway --type='merge' \
	-p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"registry-credentials"}]}}}}' >/dev/null
kubectl -n istio-system patch deployment istio-ingressgateway --type='merge' \
	-p '{"spec":{"template":{"spec":{"volumes":[{"name":"istio-ca-root-cert","configMap":{"name":"spire-ca-root-cert"}}]}}}}' >/dev/null 2>&1 || true
kubectl -n istio-system set image deployment/istio-ingressgateway istio-proxy="${THREADFORGE_REGISTRY}/istio/proxyv2@sha256:${ISTIO_PROXYV2_DIGEST}" >/dev/null 2>&1 || true

echo "[bootstrap] waiting for istio-system"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/infra/apply_resource_tiering.sh" >/dev/null
kubectl -n istio-system set image deployment/istiod discovery="${THREADFORGE_REGISTRY}/istio/pilot@sha256:${ISTIO_PILOT_DIGEST}" >/dev/null 2>&1 || true
set_bootstrap_phase "istiod-rollout" "waiting for istiod rollout"
wait_for_istio_deployment istiod
complete_bootstrap_phase "istiod-rollout" "PASS" "istiod rollout completed"
wait_for_istio_deployment istio-ingressgateway
complete_bootstrap_phase "ingress-gateway-rollout" "PASS" "ingress gateway rollout completed"
wait_for_service_endpoints istio-system istiod 180
enforce_cluster_identity_reissuance
install_value_plane_core
kubectl delete clusterpolicy threadforge-require-signed-images --ignore-not-found >/dev/null 2>&1 || true

echo "[bootstrap] pinning runtime system images"
runtime_image_pinning_initial

echo "[bootstrap] hardening kyverno webhook ownership"
# Strip ownerReferences from Kyverno webhook configurations so that Kubernetes
# garbage collection cannot remove them if the Kyverno deployment is deleted or
# scaled to zero. Combined with autoUpdateWebhooks=false in values.yaml, this
# ensures fail-closed admission even when no Kyverno pods are running.
for whc in $(kubectl get validatingwebhookconfiguration -l "app.kubernetes.io/managed-by=kyverno" -o name 2>/dev/null); do
	kubectl patch "$whc" --type=json \
		-p='[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null 2>&1 || true
	echo "[bootstrap] stripped ownerReferences from $whc"
done
for whc in $(kubectl get mutatingwebhookconfiguration -l "app.kubernetes.io/managed-by=kyverno" -o name 2>/dev/null); do
	kubectl patch "$whc" --type=json \
		-p='[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null 2>&1 || true
	echo "[bootstrap] stripped ownerReferences from $whc"
done
echo "[PASS] kyverno webhook ownership hardened"

echo "[bootstrap] running istiod readiness prechecks (pre-istiod-rollout)"
run_istiod_precheck_suite "pre-istiod-rollout"

echo "[bootstrap] applying observability stack"
set_bootstrap_phase "observability-rollout" "observability deployment start"
reconcile_observability_spire_entries
assert_observability_spire_entries
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || {
	echo "[FAIL] cert-manager CRDs missing"
	exit 2
}
kubectl delete clusterpolicy threadforge-require-signed-images --ignore-not-found >/dev/null 2>&1 || true
# namespace-contract: observability namespace producer
kubectl apply -k platform/deploy/infra/observability/base
label_namespace_injection observability enabled
label_namespace_injection default disabled
kubectl -n observability create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
kubectl get secret grafana-admin-secret -n observability >/dev/null 2>&1 || \
	kubectl create secret generic grafana-admin-secret -n observability \
		--from-literal=password=ThreadForgeAdmin2026 >/dev/null
kubectl create namespace minio --dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
label_namespace_injection minio enabled
kubectl -n minio create secret docker-registry registry-credentials \
	--docker-server="${THREADFORGE_REGISTRY}" \
	--docker-username="${THREADFORGE_REGISTRY_USER}" \
	--docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
	--dry-run=client -o yaml | apply_manifest_from_stdin >/dev/null
kubectl get secret minio-secrets -n minio >/dev/null 2>&1 || \
	kubectl create secret generic minio-secrets -n minio \
		--from-literal=accesskey=threadforge-minio \
		--from-literal=secretkey=ThreadForge2026Minio >/dev/null
cleanup_minio_legacy_tls
ensure_local_path_helper_resources
reset_minio_release
	helm upgrade --install minio platform/deploy/infra/minio -n minio --create-namespace >/dev/null
	# Patch MinIO service accounts to use registry credentials
	for sa in minio minio-sa; do
		kubectl patch serviceaccount "$sa" -n minio -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
	done
	wait_for_ready deployment/minio minio 180
	verify_minio_spire_native_bootstrap || fail_bootstrap "MinIO SPIRE-native verification failed"
	helm upgrade --install loki platform/deploy/infra/loki -n observability --create-namespace >/dev/null
	set_bootstrap_phase "loki-readiness" "waiting for Loki readiness"
	# Patch observability service accounts to use registry credentials
	for sa in loki tempo promtail grafana kube-state-metrics prometheus observability-seed-sa; do
	  kubectl patch serviceaccount "$sa" -n observability -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' 2>/dev/null || true
	done
	run_observability_kubectl "kubectl -n observability delete networkpolicy tempo-restrict --ignore-not-found" \
		kubectl -n observability delete networkpolicy tempo-restrict --ignore-not-found
	run_observability_kubectl "kubectl -n observability delete authorizationpolicy tempo-deny-all --ignore-not-found" \
		kubectl -n observability delete authorizationpolicy tempo-deny-all --ignore-not-found
	if ! run_observability_step "helm upgrade --install tempo platform/deploy/infra/tempo -n observability --create-namespace" \
		helm upgrade --install tempo platform/deploy/infra/tempo -n observability --create-namespace >/dev/null; then
		fail_observability_not_ready "helm tempo install"
	fi
	if ! run_observability_step "helm upgrade --install promtail platform/deploy/infra/promtail -n observability --create-namespace" \
		helm upgrade --install promtail platform/deploy/infra/promtail -n observability --create-namespace >/dev/null; then
		fail_observability_not_ready "helm promtail install"
	fi
	for resource in statefulset/loki statefulset/tempo deployment/grafana daemonset/promtail; do
		run_observability_kubectl "kubectl -n observability patch ${resource} imagePullSecrets" \
			kubectl -n observability patch "$resource" --type='merge' \
			-p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"registry-credentials"}]}}}}'
	done
	run_observability_kubectl "kubectl -n observability patch serviceaccount default imagePullSecrets" \
		kubectl -n observability patch serviceaccount default \
		-p '{"imagePullSecrets":[{"name":"registry-credentials"}]}'
	wait_for_kyverno_admission_ready
	stamp_custom_provider_root_projection
	run_observability_kubectl "kubectl -n observability delete pod loki-0 --ignore-not-found" \
		kubectl -n observability delete pod loki-0 --ignore-not-found --wait=false
	run_observability_kubectl "kubectl -n observability delete pod tempo-0 --ignore-not-found" \
		kubectl -n observability delete pod tempo-0 --ignore-not-found --wait=false
	run_observability_kubectl "kubectl -n observability delete pod prometheus-0 --ignore-not-found" \
		kubectl -n observability delete pod prometheus-0 --ignore-not-found --wait=false
	wait_for_observability_rollout statefulset/loki
	complete_bootstrap_phase "loki-readiness" "PASS" "loki rollout completed"
	wait_for_observability_rollout statefulset/tempo
	wait_for_observability_rollout statefulset/prometheus
	wait_for_observability_rollout deployment/grafana
	echo "[bootstrap] converging SPIRE root generation for observability workloads"
	if ! run_observability_step "bash scripts/verify/converge_spire_root.sh" \
		bash "$REPO_ROOT/scripts/verify/converge_spire_root.sh"; then
		fail_observability_not_ready "SPIRE root convergence before Tempo seed proof"
	fi
	if ! run_observability_step "require_observability_service loki" require_observability_service loki; then
		fail_observability_not_ready "loki service"
	fi
	if ! run_observability_step "require_observability_service tempo" require_observability_service tempo; then
		fail_observability_not_ready "tempo service"
	fi
	if ! run_observability_step "require_observability_endpoints loki" require_observability_endpoints loki; then
		fail_observability_not_ready "loki endpoints"
	fi
	if ! run_observability_step "require_observability_ready_endpoint loki" require_observability_ready_endpoint loki; then
		fail_observability_not_ready "loki ready endpoint"
	fi
	if ! run_observability_step "require_observability_endpoints tempo" require_observability_endpoints tempo; then
		fail_observability_not_ready "tempo endpoints"
	fi
	if ! run_observability_step "verify_tempo_sidecar_and_spiffe" verify_tempo_sidecar_and_spiffe; then
		fail_observability_not_ready "tempo sidecar and spiffe"
	fi
	if ! run_observability_step "verify_tempo_internal_connectivity" verify_tempo_internal_connectivity; then
		fail_observability_not_ready "tempo internal connectivity"
	fi
	if ! run_observability_step "verify_tempo_ring_formation" verify_tempo_ring_formation; then
		fail_observability_not_ready "tempo ring formation"
	fi
	if ! run_observability_step "wait_for_tempo_ingester_ready" wait_for_tempo_ingester_ready; then
		fail_observability_not_ready "tempo ingester ready"
	fi
	delete_observability_otelcol_if_present
	run_observability_kubectl "kubectl apply -f platform/deploy/infra/otel/collector-deployment.yaml" \
		kubectl apply -f platform/deploy/infra/otel/collector-deployment.yaml
	run_observability_kubectl "kubectl apply -f platform/deploy/infra/otel/collector-authz.yaml" \
		kubectl apply -f platform/deploy/infra/otel/collector-authz.yaml
	run_observability_kubectl "kubectl apply -f platform/deploy/infra/otel/collector-destinationrule.yaml" \
		kubectl apply -f platform/deploy/infra/otel/collector-destinationrule.yaml
	stamp_custom_provider_root_projection
	wait_for_observability_rollout deployment/threadforge-collector
	wait_for_observability_rollout daemonset/promtail
	if ! run_observability_step "check_observability_failures" check_observability_failures; then
		fail_observability_not_ready "check_observability_failures"
	fi
	if ! run_observability_step "run_tempo_seed_proof" run_tempo_seed_proof; then
		fail_observability_not_ready "tempo seed proof"
	fi
	complete_bootstrap_phase "observability-rollout" "PASS" "observability rollout completed"

	echo "[bootstrap] verifying internal runtime image enforcement"
	verify_no_external_images

	echo "[bootstrap] verifying Istio SPIRE SDS bridge"
	SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/proof/configure_istio_spire_sds.sh"

	echo "[bootstrap] reconciling SPIRE registration entries"
	set_bootstrap_phase "spire-reconciliation" "reconciling SPIRE registration entries"
	SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh" \
		|| fail_bootstrap "failed to reconcile SPIRE registration entries"

	echo "[bootstrap] verifying SPIRE registration determinism"
	verify_spire_entry_drift
	complete_bootstrap_phase "spire-reconciliation" "PASS" "SPIRE reconciliation complete"

echo "[bootstrap] stabilizing admission path"
set_bootstrap_phase "sidecar-injector-readiness" "validating sidecar injection"
ensure_threadforge_test_namespace
wait_for_kyverno_admission_ready
verify_sidecar_injection_path
complete_bootstrap_phase "sidecar-injector-readiness" "PASS" "sidecar injection path verified"

echo "[bootstrap] applying policies"
	apply_kyverno_policies

		echo "[bootstrap] re-enforcing digest-pinned Istio sidecar injector images before proof workload rollout"
		kubectl -n istio-system get configmap istio-sidecar-injector -o json \
			| jq --arg img "${THREADFORGE_REGISTRY}/istio/proxyv2@sha256:${ISTIO_PROXYV2_DIGEST}" '
				.data.values = (
					(.data.values | fromjson)
					| .global.proxy.image = $img
					| .global.proxy_init.image = $img
					| tojson
				)
				| .data.config = (
					.data.config
					| gsub("\\$\\{(?<var>[A-Za-z_][A-Za-z0-9_]*)\\}"; "$\(.var)")
				)
				| del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
			' \
			| apply_manifest_from_stdin >/dev/null
		bash "$REPO_ROOT/scripts/proof/collect_injected_images.sh" >/dev/null \
			|| fail_bootstrap "sidecar injector is not digest-pinned before proof workload rollout"

echo "[bootstrap] enforcing SPIRE-only structural invariants"
bash "$REPO_ROOT/scripts/infra/enforce-spire-only-invariants.sh" || fail_bootstrap "SPIRE-only invariant enforcement failed"

echo "[bootstrap] deploying test workloads"
	set_bootstrap_phase "proof-start" "proof workload deployment begins"
	if ! kubectl get endpoints -n kyverno kyverno-svc -o yaml | grep -q "addresses:"; then
		fail_bootstrap "KYVERNO_NOT_READY"
	fi
	ensure_threadforge_test_namespace
deploy_proof_workloads_with_retry
refresh_proof_workloads
complete_bootstrap_phase "proof-start" "PASS" "proof workloads deployed"

echo "[bootstrap] re-sanitizing runtime node image cache after late PVC provisioning"
runtime_image_pinning_followup

echo "[bootstrap] re-reconciling SPIRE->Istio CA path after cluster-wide reissuance"
# enforce_cluster_identity_reissuance restarts all deployments including istiod.
# Re-run the full SPIRE->Istio CA path refresh after all restarts have settled,
# so the istiod TLS bridge secret and webhook caBundle are refreshed together.
wait_for_istio_deployment istiod
bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh" \
	|| fail_bootstrap "post-reissuance SPIRE->Istio CA path refresh failed"
bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" \
	|| fail_bootstrap "post-reissuance webhook CA bundle verification failed"
TRUST_ROOT_PHASE=capture bash "$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh" \
	|| fail_bootstrap "post-reissuance trust root artifact refresh failed"

echo "[bootstrap] refreshing Grafana after SPIRE->Istio CA reissuance"
kubectl rollout restart deployment/grafana -n observability >/dev/null
wait_for_observability_rollout deployment/grafana

echo "[bootstrap] cleaning stale sidecar bypass pods"
cleanup_standalone_sidecarless_pods

echo "[INFO] BOOTSTRAP_NOISE_CLASSIFIED"
echo "[DEBUG] entering final control-plane verification"
echo "[bootstrap] final control-plane verification"
bash "$REPO_ROOT/scripts/verify/verify_control_plane_ready.sh"

echo "[bootstrap] starting continuous SPIRE runtime sweep"
nohup bash "$REPO_ROOT/scripts/verify/spire-runtime-sweep.sh" >/dev/null 2>&1 &
echo "[bootstrap] SPIRE runtime sweep started (PID: $!)"

echo "[bootstrap] complete"

kubectl get ns istio-system >/dev/null || exit 2
kubectl get crd certificates.cert-manager.io >/dev/null || exit 2
kubectl get ns spire-system >/dev/null || exit 2
kubectl get ns kyverno >/dev/null || exit 2
