#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# THREADFORGE EARLY WARNING SYSTEM (TEWS v1)
# Passive detection of drift, failures, and entropy pressure.
# Logs JSONL events to ~/.threadforge/alerts/
# ==============================================================================

ALERT_DIR="$HOME/.threadforge/alerts"
mkdir -p "$ALERT_DIR"

ALPHA=~/.kube/config
BRAVO=kubeconfig-bravo.yaml
CHARLIE=kubeconfig-charlie.yaml


log_alert () {
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  EVENT="$1"

  echo "⚠️  $EVENT"
  echo "{\"timestamp\": \"$TIMESTAMP\", \"event\": \"$EVENT\"}" >> "$ALERT_DIR/alerts.jsonl"
}

divider () {
  echo "--------------------------------------------------------------------------------"
}

scan_cluster () {
  CL=$1
  NAME=$2

  echo
  echo "================================================================================"
  echo "📡 TEWS: Scanning cluster: $NAME"
  echo "================================================================================"

  # ---------------------------------------------------------------------------
  # 1. cert-manager checks
  # ---------------------------------------------------------------------------
  BAD=$(kubectl get certificates -A --kubeconfig "$CL" -o json \
    | jq -r '.items[] | select(.status.conditions[].status=="False") | .metadata.namespace + "/" + .metadata.name' || true)

  if [ -n "$BAD" ]; then
    log_alert "cert-manager broken certificates detected in $NAME: $BAD"
  fi

  # Expiring soon (<48h)
  EXPIRING=$(kubectl get certificates -A --kubeconfig "$CL" -o json \
    | jq -r '.items[] | select((.status.notAfter | fromdateiso8601) - now < 172800) | .metadata.namespace + "/" + .metadata.name' || true)

  if [ -n "$EXPIRING" ]; then
    log_alert "cert-manager expiring certs (48h) in $NAME: $EXPIRING"
  fi

  # ---------------------------------------------------------------------------
  # 2. Istio sidecar injection drift
  # ---------------------------------------------------------------------------
  MISSING=$(kubectl get pods -A --kubeconfig "$CL" -o json \
    | jq -r '.items[] | select(.spec.containers | length == 1) | .metadata.namespace + "/" + .metadata.name' || true)

  if [ -n "$MISSING" ]; then
    log_alert "Istio sidecar missing pods detected in $NAME: $MISSING"
  fi

  # ---------------------------------------------------------------------------
  # 3. Gateway drift
  # ---------------------------------------------------------------------------
  GW=$(kubectl get deployments -n istio-system --kubeconfig "$CL" | grep gateway || true)
  if [ -z "$GW" ]; then
    log_alert "Istio gateway missing or drifted in $NAME"
  fi

  # ---------------------------------------------------------------------------
  # 4. PKI drift (mesh CA mismatch)
  # ---------------------------------------------------------------------------
  TEMP=$(mktemp)
  kubectl get cm tf-mesh-ca -n istio-system --kubeconfig "$CL" -o jsonpath='{.data.ca-cert\.pem}' > "$TEMP" 2>/dev/null || true

  if ! diff "$TEMP" platform/deploy/tls/intermediate/ca-chain.crt >/dev/null 2>&1; then
    log_alert "PKI drift detected in $NAME (mesh CA mismatch)"
  fi

  # ---------------------------------------------------------------------------
  # 5. Vault PKI drift (only Alpha has Vault)
  # ---------------------------------------------------------------------------
  if [ "$NAME" = "alpha" ]; then
    VAULT=$(kubectl get pods -n vault --kubeconfig "$ALPHA" | wc -l)
    if [ "$VAULT" -eq 0 ]; then
      log_alert "Vault is missing or unreachable in Alpha"
    fi
  fi

  # ---------------------------------------------------------------------------
  # 6. PodSecurity / Namespace drift
  # ---------------------------------------------------------------------------
  REQUIRED="threadforge api workers gateway dashboard vectordb"

  for NS in $REQUIRED; do
    EXISTS=$(kubectl get ns "$NS" --kubeconfig "$CL" >/dev/null 2>&1; echo $?)
    if [ "$EXISTS" -ne 0 ]; then
      log_alert "Namespace missing in $NAME: $NS"
    fi
  done

  # ---------------------------------------------------------------------------
  # 7. CrashLoopBackOff early detection
  # ---------------------------------------------------------------------------
  CRASH=$(kubectl get pods -A --kubeconfig "$CL" | grep CrashLoopBackOff || true)
  if [ -n "$CRASH" ]; then
    log_alert "CrashLoopBackOff detected in $NAME"
  fi

  # ---------------------------------------------------------------------------
  # 8. Node entropy pressure (CPU/RAM > 85%)
  # ---------------------------------------------------------------------------
  NODES=$(kubectl top nodes --kubeconfig "$CL" 2>/dev/null || true)

  if [[ "$NODES" == *"%"* ]]; then
    # Lima-style output
    while read -r line; do
      NAME_NODE=$(echo "$line" | awk '{print $1}')
      CPU=$(echo "$line" | awk '{print $3}' | tr -d '%')
      MEM=$(echo "$line" | awk '{print $5}' | tr -d '%')

      if [ "$CPU" -gt 85 ]; then
        log_alert "Node CPU pressure >85% on $NAME ($NAME_NODE)"
      fi
      if [ "$MEM" -gt 85 ]; then
        log_alert "Node memory pressure >85% on $NAME ($NAME_NODE)"
      fi

    done <<< "$(echo "$NODES" | tail -n +2)"
  fi

  # ---------------------------------------------------------------------------
  # 9. vCluster sync drift (Alpha→Bravo→Charlie)
  # ---------------------------------------------------------------------------
  if [ "$NAME" = "alpha" ]; then
    for VC in bravo charlie; do
      EXPECT=$(kubectl get ns --kubeconfig "$CL" | grep "$VC-system" || true)
      if [ -z "$EXPECT" ]; then
        log_alert "vCluster $VC desynced or missing in Alpha"
      fi
    done
  fi
}

scan_cluster "$ALPHA" "alpha"
scan_cluster "$BRAVO" "bravo"
scan_cluster "$CHARLIE" "charlie"

echo
echo "################################################################################"
echo "🎯 TEWS scan complete — alerts logged to ~/.threadforge/alerts/alerts.jsonl"
echo "################################################################################"
