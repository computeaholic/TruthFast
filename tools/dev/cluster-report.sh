#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# THREADFORGE — MULTI-CLUSTER INTELLIGENCE REPORT (TF-MCIR v1)
# Cross-cluster health report for Alpha, Bravo, Charlie
# ==============================================================================

ALPHA=~/.kube/config
BRAVO=kubeconfig-bravo.yaml
CHARLIE=kubeconfig-charlie.yaml

divider () {
  echo "--------------------------------------------------------------------------------"
}

section () {
  echo
  echo "================================================================================"
  echo "🔍  $1"
  echo "================================================================================"
}

echo
echo "################################################################################"
echo "🛰️  THREADFORGE — MULTI-CLUSTER INTELLIGENCE REPORT"
echo "################################################################################"

# ------------------------------------------------------------------------------
# 1. BASELINE: Cluster Node Health
# ------------------------------------------------------------------------------
section "1. Node Health (CPU, Memory, Runtime, K3s, ANE/GPU)"
for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 Cluster: $NAME"
  divider

  kubectl get nodes -o wide --kubeconfig "$CL" || true

  echo
  echo "[+] ANE/GPU detection:"
  kubectl describe node --kubeconfig "$CL" | grep -E "gpu|ane" || echo "  (no accelerator detected)"
  echo
done

# ------------------------------------------------------------------------------
# 2. Istio Control Plane Status
# ------------------------------------------------------------------------------
section "2. Istio Control Plane (Pilot, Gateways, Proxy & mTLS)"

for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 Cluster: $NAME"
  divider
  kubectl get pods -n istio-system --kubeconfig "$CL" -o wide || true

  echo "[+] Checking mTLS policy:"
  kubectl get peerauthentication -A --kubeconfig "$CL" || true

  echo "[+] Checking DestinationRules:"
  kubectl get destinationrule -A --kubeconfig "$CL" || true

  echo
done

# ------------------------------------------------------------------------------
# 3. Multi-Cluster Mesh Federation Integrity
# ------------------------------------------------------------------------------
section "3. Mesh Federation Integrity (Remote Secrets, MeshNetworks, EW-Gateway)"

echo "[+] Remote Secrets in Alpha:"
kubectl get secrets -n istio-system --kubeconfig "$ALPHA" | grep remote || true

echo
echo "[+] MeshNetworks applied per cluster:"
for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 $NAME MeshNetworks:"
  kubectl get cm istio -n istio-system --kubeconfig "$CL" -o=jsonpath='{.data.mesh}' || true
  echo
done

echo
echo "[+] East-west gateway status:"
for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 Cluster: $NAME"
  kubectl get pods -n istio-system --kubeconfig "$CL" | grep eastwestgateway || echo "  (not detected)"
done

# ------------------------------------------------------------------------------
# 4. PKI / CERT-MANAGER / CA CHAIN STATUS
# ------------------------------------------------------------------------------
section "4. PKI Chain: Root → Intermediate → Issuers → Secrets"

for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 Cluster: $NAME"
  divider

  kubectl get certificates -A --kubeconfig "$CL" || true
  kubectl get issuers -A --kubeconfig "$CL" || true
  kubectl get clusterissuers -A --kubeconfig "$CL" || true
  kubectl get secrets -n cert-manager --kubeconfig "$CL" | grep ca || echo "  (no CA secrets)"

  echo
done

# ------------------------------------------------------------------------------
# 5. Vault Replication + PKI Sync Status
# ------------------------------------------------------------------------------
section "5. Vault PKI / Replication Status"

echo "[+] Alpha Vault pods:"
kubectl get pods -n vault --kubeconfig "$ALPHA" || true

echo
echo "[+] Checking PKI mount:"
kubectl exec -n vault platform/deploy/vault --kubeconfig "$ALPHA" -- \
  vault secrets list | grep pki || echo "  (pki not mounted)"

echo
echo "[+] Checking replication tasks:"
bash scripts/mc/vault-replicate.sh --check || true

# ------------------------------------------------------------------------------
# 6. Sidecar Injection Status Across Service Namespaces
# ------------------------------------------------------------------------------
section "6. Sidecar Injection & PodSecurity (Strict Mode)"

for NS in threadforge weave api workers dashboard gateway; do
  echo "📂 Namespace: $NS"
  divider
  kubectl get pods -n "$NS" --kubeconfig "$ALPHA" -o json | jq '.items[].spec.containers[].name' || true
done

# ------------------------------------------------------------------------------
# 7. Service Discovery (Cross-cluster Endpoint Resolution)
# ------------------------------------------------------------------------------
section "7. Service Discovery Verification"

for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}

  echo "📌 $NAME:"
  istioctl pc endpoints platform/deploy/istio-ingressgateway \
    -n istio-system \
    --kubeconfig "$CL" || true
done

# ------------------------------------------------------------------------------
# 8. Routing Table Dump
# ------------------------------------------------------------------------------
section "8. Multi-Cluster Routing Table Dump"

for CL in "$ALPHA" "$BRAVO" "$CHARLIE"; do
  NAME=$(basename "$CL" .yaml)
  NAME=${NAME:-alpha}
  echo "📌 Endpoints for $NAME"
  kubectl get endpoints -A --kubeconfig "$CL" || true
done

echo
echo "################################################################################"
echo "🎉 THREADFORGE MCIR REPORT COMPLETE"
echo "################################################################################"
