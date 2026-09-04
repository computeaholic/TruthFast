#!/usr/bin/env bash
set -euo pipefail

out_file="${1:-_ci_parity/ci_environment_snapshot.txt}"
mkdir -p "$(dirname "$out_file")"

{
  echo "THREADFORGE_CI_ENVIRONMENT_SNAPSHOT"
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pwd=$(pwd)"
  echo "PATH=$PATH"
  echo

  run_cmd() {
    local label="$1"
    shift
    echo "### ${label}"
    echo "$ $*"
    set +e
    timeout 20s "$@"
    local rc=$?
    set -e
    echo "exit_code=${rc}"
    echo
  }

  run_cmd "which cosign" which cosign
  run_cmd "cosign version" cosign version

  run_cmd "which kubectl" which kubectl
  run_cmd "kubectl version --client" kubectl version --client

  run_cmd "which helm" which helm
  run_cmd "helm version" helm version

  run_cmd "which kind" which kind
  run_cmd "kind version" kind version

  run_cmd "which istioctl" which istioctl
  run_cmd "istioctl version" istioctl version

  run_cmd "which docker" which docker
  run_cmd "docker --version" docker --version

  run_cmd "which jq" which jq
  run_cmd "jq --version" jq --version

  run_cmd "which yq" which yq
  run_cmd "yq --version" yq --version

  run_cmd "which openssl" which openssl
  run_cmd "openssl version" openssl version

  run_cmd "which python3" which python3
  run_cmd "python3 --version" python3 --version

  run_cmd "which make" which make
  run_cmd "make --version" make --version

  echo "### env | sort"
  timeout 20s env | sort
} >"$out_file"

echo "[ci-parity] wrote snapshot: $out_file"
