#!/usr/bin/env bash
# =============================================================================
# ThreadForge — Helm Template Integrity Guard
# =============================================================================
# Scans Helm chart templates for malformed double-brace syntax:
#   { {  and  } }  (spaces inserted inside Helm delimiters)
#
# Valid Helm:     {{ .Release.Namespace }}   {{ .Values.foo }}
# Invalid (YAML parse error): { { .Release.Namespace } }
#
# CONTRACT_VIOLATION exit code: 2
# Usage: bash scripts/verify/verify_helm_template_integrity.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
exec python3 "$REPO_ROOT/scripts/verify/helm_template_integrity.py" "$@"
