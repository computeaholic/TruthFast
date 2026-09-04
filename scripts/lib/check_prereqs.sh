#!/usr/bin/env bash
# check_prereqs.sh — ENV CONTRACT: fail fast with actionable errors if required
# tools or environment variables are missing.
#
# Exit codes:
#   0  — all checks passed
#   10 — one or more required prereqs are missing
#
# Usage:
#   bash scripts/lib/check_prereqs.sh
#   source scripts/lib/check_prereqs.sh  (in other scripts)
set -euo pipefail

FAIL=0

require_tool() {
  local tool="$1" install_hint="${2:-}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[FAIL] MISSING_PREREQ: '$tool' not found in PATH"
    if [ -n "$install_hint" ]; then
      echo "       Install: $install_hint"
    fi
    FAIL=1
  fi
}

require_env() {
  local var="$1" hint="${2:-}"
  if [ -z "${!var:-}" ]; then
    echo "[FAIL] MISSING_PREREQ: environment variable '$var' is not set"
    if [ -n "$hint" ]; then
      echo "       ${hint}"
    fi
    FAIL=1
  fi
}

# ── Required tools ────────────────────────────────────────────────────────────
require_tool docker    "https://docs.docker.com/engine/install/"
require_tool git       "https://git-scm.com/downloads"
require_tool kind      "go install sigs.k8s.io/kind@latest  OR  https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
require_tool kubectl   "https://kubernetes.io/docs/tasks/tools/"
require_tool cosign    "go install github.com/sigstore/cosign/v2/cmd/cosign@latest  OR  https://docs.sigstore.dev/cosign/system_config/installation/"
require_tool helm      "https://helm.sh/docs/intro/install/"
require_tool jq        "apt install jq  OR  brew install jq"
require_tool python3   "https://www.python.org/downloads/"
require_tool skopeo    "https://github.com/containers/skopeo/blob/main/install.md"
require_tool istioctl  "https://istio.io/latest/docs/setup/getting-started/#download"

# ── Connectivity: Docker daemon must be running ────────────────────────────────
if [ "$FAIL" -eq 0 ] && ! docker info >/dev/null 2>&1; then
  echo "[FAIL] MISSING_PREREQ: Docker daemon is not running"
  echo "       Start Docker and rerun 'make proof'"
  FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
  echo ""
  echo "[FAIL] One or more required tools/environment prerequisites are missing."
  echo "       Install the missing tools above and then rerun:  make proof"
  exit 10
fi

echo "[OK] all required tools present (docker, git, kind, kubectl, cosign, helm, jq, python3, skopeo, istioctl)"
