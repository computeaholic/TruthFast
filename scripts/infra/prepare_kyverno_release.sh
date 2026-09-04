#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
RELEASE_NAME="${KYVERNO_RELEASE_NAME:-kyverno}"

fail() {
	echo "[FAIL] $*" >&2
	exit 2
}

is_helm_owned() {
	local kind="$1"
	local name="$2"
	local managed_by release_name release_namespace

	managed_by="$(kubectl -n "${NAMESPACE}" get "${kind}" "${name}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
	release_name="$(kubectl -n "${NAMESPACE}" get "${kind}" "${name}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
	release_namespace="$(kubectl -n "${NAMESPACE}" get "${kind}" "${name}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)"

	[[ "${managed_by}" == "Helm" && "${release_name}" == "${RELEASE_NAME}" && "${release_namespace}" == "${NAMESPACE}" ]]
}

require_helm_ownership_or_absent() {
	local kind="$1"
	local name="$2"

	if ! kubectl -n "${NAMESPACE}" get "${kind}" "${name}" >/dev/null 2>&1; then
		return 0
	fi

	if ! is_helm_owned "${kind}" "${name}"; then
		fail "unmanaged Kyverno resource blocks Helm reconciliation: ${kind}/${name}"
	fi
}

delete_if_present() {
	local kind="$1"
	local name="$2"

	kubectl -n "${NAMESPACE}" delete "${kind}" "${name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

main() {
	local service_name deployment_name cronjob_name

	kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}" >/dev/null

	for service_name in \
		kyverno-background-controller-metrics \
		kyverno-cleanup-controller-metrics \
		kyverno-reports-controller-metrics \
		kyverno-svc-admission \
		kyverno-svc-metrics; do
		require_helm_ownership_or_absent service "${service_name}"
		delete_if_present service "${service_name}"
	done

	for deployment_name in \
		kyverno-admission-controller \
		kyverno-background-controller \
		kyverno-cleanup-controller \
		kyverno-reports-controller; do
		require_helm_ownership_or_absent deployment "${deployment_name}"
		delete_if_present deployment "${deployment_name}"
	done

	for cronjob_name in \
		kyverno-cleanup-admission-reports \
		kyverno-cleanup-cluster-admission-reports \
		kyverno-cleanup-cluster-ephemeral-reports \
		kyverno-cleanup-ephemeral-reports \
		kyverno-cleanup-update-requests; do
		require_helm_ownership_or_absent cronjob "${cronjob_name}"
		delete_if_present cronjob "${cronjob_name}"
	done
}

main "$@"
