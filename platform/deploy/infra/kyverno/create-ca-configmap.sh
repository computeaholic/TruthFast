#!/usr/bin/env bash
# Creates the kyverno-combined-ca-bundle ConfigMap from the kind node's system CA bundle
# combined with the ThreadForge ingress CA.
# Must run before `helm upgrade kyverno` if the configmap doesn't exist.
set -euo pipefail

NAMESPACE=${1:-kyverno}

# Get the combined CA from the kind node (system CAs + ingress CA)
docker exec threadforge-control-plane cat /etc/ssl/certs/ca-certificates.crt > /tmp/system-cas.crt
INGRESS_CA=$(docker exec threadforge-control-plane cat /etc/ssl/certs/threadforge-ingress-ca.pem)

# Combine: system CAs first, then ingress CA
cat /tmp/system-cas.crt > /tmp/combined-ca-bundle.crt
echo "" >> /tmp/combined-ca-bundle.crt
echo "$INGRESS_CA" >> /tmp/combined-ca-bundle.crt

kubectl create configmap kyverno-combined-ca-bundle \
  --from-file=ca-certificates=/tmp/combined-ca-bundle.crt \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "kyverno-combined-ca-bundle ConfigMap created/updated in namespace ${NAMESPACE}"
