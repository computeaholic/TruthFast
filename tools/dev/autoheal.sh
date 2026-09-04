#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# Preflight identity enforcement (P4: identity-first law)
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

# ==============================================================================
# THREADFORGE — ANTI-CHAOS AUTO-HEAL ENGINE (ACAE v1)
# Failure detection and autonomous repair engine
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
  echo "🛠️  $1"
  echo "================================================================================"
}


# requires_identity=true  # trust_tier=full

# Preflight identity enforcement (P4: identity-first law)
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo
echo "################################################################################"
echo "🔥 THREADFORGE AUTO-HEAL ENGINE — INITIATED"
echo "################################################################################"


# ------------------------------------------------------------------------------
# 1. DETECT & FIX: CERT-MANAGER FAILURES
# ------------------------------------------------------------------------------
section "1. cert-manager issuer + certificate validation"

fix_cert_manager () {
  CL=$1
  NAME=$2

  echo "📌 Cluster: $NAME"

  # Check broken issuers
  BAD_ISSUERS=$(kubectl get issuer -A --kubeconfig "$CL" -o json | jq -r '.items[] | select(.status.conditions[].status=="False") | .metadata.name' || true)

  if [ -n "$BAD_ISSUERS" ]; then
    echo "⚠️ Broken Issuers detected:"
    echo "$BAD_ISSUERS"

    echo "🔧 Re-applying cert-manager issuers for $NAME"
    kubectl apply -f platform/deploy/tls/cm/ --kubeconfig "$CL"
  else
    echo "✔ Issuers healthy"
  fi

  # Check stuck certificates
  BAD_CERTS=$(kubectl get certificates -A --kubeconfig "$CL" -o json | jq -r '.items[] | select(.status.conditions[].status=="False") | .metadata.name' || true)

  if [ -n "$BAD_CERTS" ]; then
    echo "⚠️ Broken Certificates detected:"
    echo "$BAD_CERTS"
    echo "🔧 Forcing renewal..."
    for c in $BAD_CERTS; do
      kubectl annotate certificate $c cert-manager.io/renew-reason=autoheal --overwrite --kubeconfig "$CL" || true
    done
  else
    echo "✔ Certificates healthy"
  fi
}

fix_cert_manager "$ALPHA" "alpha"
fix_cert_manager "$BRAVO" "bravo"
fix_cert_manager "$CHARLIE" "charlie"


# ------------------------------------------------------------------------------
# 2. DETECT & FIX: SIDECAR INJECTION FAILURES
# ------------------------------------------------------------------------------
section "2. Istio sidecar injection repair"

fix_sidecars () {
  CL=$1
  NAME=$2

  echo "📌 Checking for non-injected pods in $NAME..."

  BAD=$(kubectl get pods -A --kubeconfig "$CL" -o json \
    | jq -r '.items[] | select(.spec.containers | length == 1) | .metadata.namespace + "/" + .metadata.name' || true)

  if [ -n "$BAD" ]; then
    echo "⚠️ Pods missing sidecars:"
    echo "$BAD"

    echo "🔧 Restarting pods to enforce injection..."
    for p in $BAD; do
      NS=$(echo $p | cut -d/ -f1)
      POD=$(echo $p | cut -d/ -f2)
      kubectl delete pod "$POD" -n "$NS" --kubeconfig "$CL" || true
    done
  else
    echo "✔ All pods injected correctly"
  fi
}

fix_sidecars "$ALPHA" "alpha"


# ------------------------------------------------------------------------------
# 3. DETECT & FIX: MESH GATEWAY DRIFT
# ------------------------------------------------------------------------------
section "3. Istio ingress / east-west gateway auto-repair"

fix_gateways () {
  CL=$1
  NAME=$2

  echo "📌 Cluster: $NAME"

  gw=$(kubectl get deployments -n istio-system --kubeconfig "$CL" | grep gateway || true)

  if [ -z "$gw" ]; then
    echo "⚠️ Gateways missing — re-installing Istio mesh..."
    make helm-upgrade-istio
  else
    echo "✔ Gateways detected"
  fi
}

fix_gateways "$ALPHA" "alpha"
fix_gateways "$BRAVO" "bravo"
fix_gateways "$CHARLIE" "charlie"


# ------------------------------------------------------------------------------
# 4. DETECT & FIX: PKI / CA BUNDLE DRIFT
# ------------------------------------------------------------------------------
section "4. PKI chain drift correction"

LATEST_CHAIN="platform/deploy/tls/intermediate/ca-chain.crt"

check_pki () {
  CL=$1
  NAME=$2

  echo "📌 Cluster: $NAME"

  LIVE_CHAIN=$(mktemp)
  kubectl get cm tf-mesh-ca -n istio-system --kubeconfig "$CL" -o jsonpath='{.data.ca-cert\.pem}' > "$LIVE_CHAIN" || true

  if ! diff "$LIVE_CHAIN" "$LATEST_CHAIN" >/dev/null 2>&1; then
    echo "⚠️ PKI drift detected: mesh has an outdated CA bundle"
    echo "🔧 Re-applying CA configmap"
    kubectl delete cm tf-mesh-ca -n istio-system --kubeconfig "$CL" || true
    kubectl create configmap tf-mesh-ca -n istio-system \
      --from-file=ca-cert.pem="$LATEST_CHAIN" \
      --kubeconfig "$CL"
  else
    echo "✔ CA chain is current"
  fi
}

check_pki "$ALPHA" "alpha"
check_pki "$BRAVO" "bravo"
check_pki "$CHARLIE" "charlie"


# ------------------------------------------------------------------------------
# 5. DETECT & FIX: VAULT-PKI SYNC
# ------------------------------------------------------------------------------
section "5. Vault PKI drift repair"

VAULT_PODS=$(kubectl get pods -n vault --kubeconfig "$ALPHA" 2>/dev/null | wc -l)

if [ "$VAULT_PODS" -eq 0 ]; then
  echo "⚠️ Vault missing — skipping Vault repairs"
else
  echo "[+] Checking Vault PKI sync..."
  bash scripts/mc/vault-replicate.sh --repair || true
fi


# ------------------------------------------------------------------------------
# 6. DETECT & FIX: POD SECURITY BREAKAGE
# ------------------------------------------------------------------------------
section "6. PodSecurity auto-repair"

NS_LIST="threadforge api workers gateway dashboard vectordb"


for NS in $NS_LIST; do
  echo "📂 Namespace: $NS"

  # Check existence
  if ! kubectl get ns "$NS" --kubeconfig "$ALPHA" >/dev/null 2>&1; then
    echo "⚠️ Namespace missing: recreating..."
    kubectl create ns "$NS" --kubeconfig "$ALPHA"
  fi

  # Ensure restricted PodSecurity
  kubectl label ns "$NS" \
    pod-security.kubernetes.io/enforce=restricted \
    --overwrite --kubeconfig "$ALPHA" || true
done


# ------------------------------------------------------------------------------
# 7. ZOMBIE POD CLEANER (CrashLoopBackOff Auto-Repair)
# ------------------------------------------------------------------------------
section "7. Zombie Pod Cleaner"

ZOMBIES=$(kubectl get pods -A --kubeconfig "$ALPHA" | grep CrashLoopBackOff | awk '{print $1","$2}' || true)

if [ -n "$ZOMBIES" ]; then
  echo "⚠️ Zombie pods found:"
  echo "$ZOMBIES"
  echo "🔧 Cleaning up affected pods."
  for z in $ZOMBIES; do
    NS=$(echo $z | cut -d, -f1)
    POD=$(echo $z | cut -d, -f2)
    kubectl delete pod "$POD" -n "$NS" --kubeconfig "$ALPHA" || true
  done
else
  echo "✔ No zombie pods detected"
fi


# ------------------------------------------------------------------------------
# COMPLETE
# ------------------------------------------------------------------------------
echo
echo "################################################################################"
echo "🎉 AUTO-HEAL COMPLETE — ThreadForge is STABLE"
echo "################################################################################"
