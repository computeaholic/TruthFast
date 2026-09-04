#!/usr/bin/env bash
set -euo pipefail

THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
ISTIO_TAG="${ISTIO_TAG:-1.29.0}"
ISTIO_PILOT_DIGEST="${ISTIO_PILOT_DIGEST:-32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f}"
ISTIO_PROXYV2_DIGEST="${ISTIO_PROXYV2_DIGEST:-2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

verify_no_external_images() {
  local images
  images="$(kubectl get pods -n istio-system -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sed '/^$/d' | grep -v "^${THREADFORGE_REGISTRY}/" || true)"
  if [[ -n "${images}" ]]; then
    printf '%s\n' "${images}" | sort -u
    echo "[FAIL] external images detected after Istio install"
    exit 2
  fi
}

ensure_gateway_root_projection() {
  local deployment_name="$1"
  if ! kubectl -n istio-system get deployment "${deployment_name}" >/dev/null 2>&1; then
    return 0
  fi

  if ! kubectl -n istio-system get deployment "${deployment_name}" -o json | jq -e '
    .spec.template.spec.containers[]?
    | select(.name == "istio-proxy")
    | any(.volumeMounts[]?; .name == "istio-ca-root-cert" and .mountPath == "/etc/certs")
  ' >/dev/null 2>&1; then
    kubectl -n istio-system patch deployment "${deployment_name}" --type='merge' \
      -p '{"spec":{"template":{"spec":{"volumes":[{"name":"istio-ca-root-cert","configMap":{"name":"spire-ca-root-cert"}}],"containers":[{"name":"istio-proxy","volumeMounts":[{"name":"istio-ca-root-cert","mountPath":"/etc/certs","readOnly":true}]}]}}}}' >/dev/null
  fi

  kubectl -n istio-system set image deployment/"${deployment_name}" istio-proxy="${THREADFORGE_REGISTRY}/istio/proxyv2@sha256:${ISTIO_PROXYV2_DIGEST}" >/dev/null 2>&1 || true
}

echo "[ISTIO] Installing Istio (clean + idempotent)..."

if kubectl get namespace istio-system >/dev/null 2>&1; then
  ISTIO_NS_PHASE="$(kubectl get namespace istio-system -o jsonpath='{.status.phase}')"
  if [[ "${ISTIO_NS_PHASE}" == "Terminating" ]]; then
    echo "[ERROR] istio-system namespace is terminating"
    kubectl get namespace istio-system -o yaml
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

if ! command -v istioctl >/dev/null 2>&1; then
  echo "[ERROR] istioctl not found"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

bash "${REPO_ROOT}/scripts/install/prepare_istio_images.sh"
istioctl install \
  --set profile=demo \
  --set hub="${THREADFORGE_REGISTRY}/istio" \
  --set tag="${ISTIO_TAG}" \
  --set meshConfig.trustDomain="${SPIFFE_TRUST_DOMAIN}" \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set meshConfig.accessLogEncoding=JSON \
  --set meshConfig.accessLogFormat='{"authority":"%REQ(:AUTHORITY)%","method":"%REQ(:METHOD)%","path":"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%","response_code":"%RESPONSE_CODE%","downstream_peer_uri_san":"%DOWNSTREAM_PEER_URI_SAN%","downstream_local_uri_san":"%DOWNSTREAM_LOCAL_URI_SAN%","upstream_peer_uri_san":"%UPSTREAM_PEER_URI_SAN%","upstream_local_uri_san":"%UPSTREAM_LOCAL_URI_SAN%","x_forwarded_client_cert":"%REQ(X-FORWARDED-CLIENT-CERT)%"}' \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
  --set values.global.pilotCertProvider=custom \
  --set values.global.caAddress=spire-csr.istio-system.svc:443 \
  --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_CERT_SIGNER=spire-csr \
  -y

echo "[ISTIO] Enforcing digest-pinned sidecar injector images"
kubectl -n istio-system get configmap istio-sidecar-injector -o json \
  | jq --arg img "${THREADFORGE_REGISTRY}/istio/proxyv2@sha256:${ISTIO_PROXYV2_DIGEST}" '
      .data.values = (
        (.data.values | fromjson)
        | .global.proxy.image = $img
        | .global.proxy_init.image = $img
        | .global.mountMtlsCerts = true
        | tojson
      )
      | .data.config = (
        .data.config
        | gsub("\\$\\{(?<var>[A-Za-z_][A-Za-z0-9_]*)\\}"; "$\(.var)")
      )
      | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)
    ' \
  | kubectl apply -f - >/dev/null

echo "[ISTIO] Refreshing SPIRE->Istio CA path"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "${REPO_ROOT}/scripts/verify/refresh_spire_istio_ca_path.sh"

SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN}" bash "${REPO_ROOT}/scripts/proof/configure_istio_spire_sds.sh"

echo "[ISTIO] Waiting for control plane..."

kubectl -n istio-system set image deployment/istiod discovery="${THREADFORGE_REGISTRY}/istio/pilot@sha256:${ISTIO_PILOT_DIGEST}" >/dev/null

bash "${REPO_ROOT}/scripts/install/enforce_istiod_startup_order.sh"

kubectl rollout status deployment/istiod -n istio-system --timeout=120s
ensure_gateway_root_projection istio-ingressgateway
ensure_gateway_root_projection istio-egressgateway
kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=120s
kubectl rollout status deployment/istio-egressgateway -n istio-system --timeout=120s

verify_no_external_images

echo "[ISTIO] Verifying service..."

kubectl get svc istiod -n istio-system

echo "[ISTIO] Install complete"
