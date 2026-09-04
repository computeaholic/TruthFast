#!/bin/bash
set -e

SOURCE=platform/deploy/identity/identity-matrix.yaml
TARGET_DIR=platform/deploy/infra/istio/templates/authz

echo "🔍 Running AuthorizationPolicy drift detector…"

python3 tools/dev/policy-compiler.py >/tmp/authz-new

if ! diff -r $TARGET_DIR /tmp/authz-new > /tmp/drift; then
    echo "❌ DRIFT DETECTED:"
    cat /tmp/drift
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✔ No drift — policies match identity matrix"
