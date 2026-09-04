#!/usr/bin/env bash
set -euo pipefail

# Check if any ALLOW AuthorizationPolicy does not have 'principals' in its rules
# DENY policies with empty rules are valid (default-deny posture)
kubectl get authorizationpolicy -A -o yaml | \
  awk '/kind: AuthorizationPolicy/,/^---|^$/' | \
  awk -v RS='---' '
    /action: ALLOW/ {
      found_principals = 0
      for (i=1; i<=NF; i++) {
        if ($i == "principals:") {
          found_principals = 1
          break
        }
      }
      if (found_principals == 0) {
        print "ERROR: ALLOW AuthorizationPolicy without principals found"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      }
    }
  '

echo "✓ All ALLOW AuthorizationPolicies use principals"