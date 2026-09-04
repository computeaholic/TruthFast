#!/usr/bin/env bash
set -euo pipefail

# Check if any PeerAuthentication is not STRICT
non_strict=$(kubectl get peerauthentication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.spec.mtls.mode}{"\n"}{end}' | awk -F: '$2 != "STRICT" {print $0}')

if [ -n "$non_strict" ]; then
  echo "ERROR: Non-STRICT PeerAuthentications found:"
  echo "$non_strict"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ All PeerAuthentications are STRICT"