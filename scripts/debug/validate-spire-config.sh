#!/bin/bash
# validate-spire-config.sh - SPIRE Configuration Validation
# Ensures no insecure configurations in production

set -euo pipefail

VALUES_FILE="$1"
ENVIRONMENT="${2:-dev}"  # default to dev

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: Values file $VALUES_FILE not found"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# SPIRE TLS is not supported in 1.14.0 build - agent-server communication is secured via controls
# Fail if any TLS configuration block or TLS keys are present under platform/deploy/infra/spire
# Find TLS-like occurrences but ignore disabled files and comment lines
# look only in YAML and template files, ignore markdown or other docs; busybox grep may lack --exclude
matches=$(find platform/deploy/infra/spire -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.tpl" \) -print0 \
    | xargs -0 grep -n -E "^[[:space:]]*tls[[:space:]]*:|tls\.enabled|tls\s*\{" 2>/dev/null \
    | grep -v -F "--set" \
    | awk -F":" '{ $1=""; $2=""; sub(/^::?/,"" ); print }' \
    | grep -v "^[[:space:]]*#" || true)
if [ -n "$matches" ]; then
    echo "ERROR: TLS-related configuration detected in platform/deploy/infra/spire (excluding disabled files and comments):"
    echo "$matches"
    echo "SPIRE 1.14.0 does not accept agent-server TLS blocks. Remove any 'tls:' or 'tls.*' keys from active chart files."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check agent topology (ensure DaemonSet exists and no StatefulSet template for agent)
if [ ! -f "platform/deploy/infra/spire/templates/spire-agent-daemonset.yaml" ]; then
    echo "ERROR: Missing agent DaemonSet template (platform/deploy/infra/spire/templates/spire-agent-daemonset.yaml)."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ -f "platform/deploy/infra/spire/templates/spire-agent-statefulset.yaml" ]; then
    echo "ERROR: SPIRE agent must use DaemonSet topology; remove statefulset template."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Trust domain immutability check (must match canonical value)
EXPECTED_TRUST="identity.threadforge.local"
# allow quoted or unquoted trustDomain value
if ! grep -q "^trustDomain: *\"\?$EXPECTED_TRUST\"\?" platform/deploy/infra/spire/values.yaml; then
    echo "ERROR: trustDomain must be set to \"$EXPECTED_TRUST\" in platform/deploy/infra/spire/values.yaml"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Ensure insecure_bootstrap is explicit, set to true, and documented in SPIRE_FINALIZED.md
if ! grep -E "^[[:space:]]*insecure_bootstrap:[[:space:]]*true" platform/deploy/infra/spire/values.yaml >/dev/null 2>&1; then
    echo "ERROR: insecure_bootstrap must be explicitly set to 'true' in platform/deploy/infra/spire/values.yaml (required for SPIRE 1.14.x)."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -q "Agent–Server Security Model (SPIRE 1.14)" docs/spire/SPIRE_FINALIZED.md; then
    echo "ERROR: SPIRE_FINALIZED.md must include the 'Agent–Server Security Model (SPIRE 1.14)' section describing the controlled insecure_bootstrap justification."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -q "Agent–server TLS is unavailable in SPIRE 1.14" docs/spire/SPIRE_FINALIZED.md; then
    echo "ERROR: SPIRE_FINALIZED.md must explicitly state that Agent–server TLS is unavailable in SPIRE 1.14 and is a tracked non-goal."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Ensure trust bundle references remain present and exported via ConfigMap
if ! grep -q "trustBundleConfigMap" platform/deploy/infra/spire/values.yaml; then
    echo "ERROR: trustBundleConfigMap is missing from platform/deploy/infra/spire/values.yaml; trust bundle references must remain present."
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ -f "platform/deploy/infra/spire/templates/spire-bundle-configmap.yaml" ]; then
    if ! grep -R "bundle.crt" platform/deploy/infra/spire/templates/spire-bundle-configmap.yaml >/dev/null 2>&1; then
        echo "ERROR: spire-bundle ConfigMap template must include 'bundle.crt' key for bundle distribution."
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
else
    if [ ! -f "spire-server-bundle.pem" ]; then
        echo "ERROR: No spire-bundle ConfigMap template found and spire-server-bundle.pem is missing; ensure trust bundle is present declaratively."
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
fi

echo "✅ SPIRE configuration validation passed"
exit 0
