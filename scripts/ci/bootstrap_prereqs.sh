#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

SCRIPT_START_TS="$(date +%s)"
PHASE_START_TS="$SCRIPT_START_TS"
CURRENT_PHASE="start"

phase_start() {
  CURRENT_PHASE="$1"
  PHASE_START_TS="$(date +%s)"
  echo "[ci-parity] phase=${CURRENT_PHASE}"
}

phase_done() {
  local now elapsed
  now="$(date +%s)"
  elapsed="$((now - PHASE_START_TS))"
  echo "[ci-parity] phase=${CURRENT_PHASE} completed elapsed_s=${elapsed}"
}

process_inventory() {
  echo "[ci-parity] process-inventory begin"
  ps -eo pid,ppid,pgid,stat,etime,args | awk -v self="$$" '$1==self || $2==self || $3==self {print}' || true
  echo "[ci-parity] process-inventory end"
}

on_exit() {
  local rc total_elapsed
  rc="$1"
  total_elapsed="$(( $(date +%s) - SCRIPT_START_TS ))"
  echo "[ci-parity] exit rc=${rc} last_phase=${CURRENT_PHASE} total_elapsed_s=${total_elapsed}"
  process_inventory
}

trap 'on_exit $?' EXIT

run_cmd() {
  local label="$1"
  shift
  echo "[ci-parity] run=${label}"
  "$@"
}

run_cmd_timeout() {
  local label="$1"
  local timeout_s="$2"
  shift 2
  echo "[ci-parity] run=${label} timeout_s=${timeout_s}"
  timeout "${timeout_s}s" "$@"
}

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
fi
export PATH="$BIN_DIR:$PATH"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "[FAIL] Unsupported architecture: $ARCH_RAW"
    exit 2
    ;;
esac

COSIGN_VERSION="v2.4.1"
KUBECTL_VERSION="v1.35.1"
HELM_VERSION="v4.2.0"
KIND_VERSION="v0.22.0"
ISTIO_VERSION="${THREADFORGE_EXPECTED_ISTIO_VERSION:-1.29.0}"
YQ_VERSION="v4.44.3"

curl_download() {
  local url="$1"
  local out_file="$2"
  run_cmd_timeout "curl:${url}" 180 \
    curl --fail --show-error --silent --location \
      --connect-timeout 10 \
      --max-time 180 \
      --retry 2 \
      --retry-delay 2 \
      --retry-all-errors \
      "$url" -o "$out_file"
}

fetch_bin() {
  local url="$1"
  local target="$2"
  local tmp
  tmp="$(mktemp)"
  echo "[ci-parity] download: $url"
  curl_download "$url" "$tmp"
  run_cmd_timeout "install:${target}" 20 install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
}

install_cosign() {
  fetch_bin \
    "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${ARCH}" \
    "${BIN_DIR}/cosign"
}

install_kubectl() {
  fetch_bin \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    "${BIN_DIR}/kubectl"
}

install_helm() {
  local tar_arch
  tar_arch="linux-${ARCH}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  echo "[ci-parity] download: https://get.helm.sh/helm-${HELM_VERSION}-${tar_arch}.tar.gz"
  curl_download "https://get.helm.sh/helm-${HELM_VERSION}-${tar_arch}.tar.gz" "${tmp_dir}/helm.tgz"
  run_cmd_timeout "tar:helm" 30 tar -xzf "${tmp_dir}/helm.tgz" -C "$tmp_dir"
  run_cmd_timeout "install:helm" 20 install -m 0755 "${tmp_dir}/${tar_arch}/helm" "${BIN_DIR}/helm"
  rm -rf "$tmp_dir"
}

install_kind() {
  fetch_bin \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
    "${BIN_DIR}/kind"
}

install_istioctl() {
  local istio_arch
  if [[ "$ARCH" == "amd64" ]]; then
    istio_arch="x86_64"
  else
    istio_arch="arm64"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local tarball="istio-${ISTIO_VERSION}-linux-${istio_arch}.tar.gz"
  local url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${tarball}"

  echo "[ci-parity] download: $url"
  curl_download "$url" "${tmp_dir}/${tarball}"
  run_cmd_timeout "tar:istioctl" 45 tar -xzf "${tmp_dir}/${tarball}" -C "$tmp_dir"
  run_cmd_timeout "install:istioctl" 20 install -m 0755 "${tmp_dir}/istio-${ISTIO_VERSION}/bin/istioctl" "${BIN_DIR}/istioctl"
  rm -rf "$tmp_dir"
}

install_yq() {
  fetch_bin \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
    "${BIN_DIR}/yq"
}

phase_start "start"
echo "[ci-parity] bootstrap-start bin_dir=${BIN_DIR}"
phase_done

phase_start "download-cosign"
install_cosign
echo "[ci-parity] completed=cosign"
phase_done

phase_start "download-kubectl"
install_kubectl
echo "[ci-parity] completed=kubectl"
phase_done

phase_start "download-helm"
install_helm
echo "[ci-parity] completed=helm"
phase_done

phase_start "download-kind"
install_kind
echo "[ci-parity] completed=kind"
phase_done

phase_start "download-istioctl"
install_istioctl
echo "[ci-parity] completed=istioctl"
phase_done

phase_start "download-yq"
install_yq
echo "[ci-parity] completed=yq"
phase_done

phase_start "verify-path"
run_cmd "which:cosign" which cosign
run_cmd "which:kubectl" which kubectl
run_cmd "which:helm" which helm
run_cmd "which:kind" which kind
run_cmd "which:istioctl" which istioctl
run_cmd "which:yq" which yq
phase_done

phase_start "verify-cosign"
run_cmd_timeout "cosign:version" 20 cosign version
phase_done

phase_start "verify-kubectl"
run_cmd_timeout "kubectl:version" 20 kubectl version --client
phase_done

phase_start "verify-helm"
run_cmd_timeout "helm:version" 20 helm version
phase_done

phase_start "verify-kind"
run_cmd_timeout "kind:version" 20 kind version
phase_done

phase_start "verify-istioctl"
run_cmd_timeout "istioctl:version" 20 istioctl version --remote=false
phase_done

phase_start "verify-yq"
run_cmd_timeout "yq:version" 20 yq --version
phase_done

echo "[ci-parity] Verifying runtime prerequisites required by authoritative Makefile"
phase_start "verify-runtime-prereqs"
run_cmd "which:docker" which docker
run_cmd_timeout "docker:version" 20 docker --version
run_cmd "which:jq" which jq
run_cmd_timeout "jq:version" 20 jq --version
run_cmd "which:openssl" which openssl
run_cmd_timeout "openssl:version" 20 openssl version
run_cmd "which:python3" which python3
run_cmd_timeout "python3:version" 20 python3 --version
run_cmd "which:make" which make
run_cmd_timeout "make:version" 20 bash -lc 'make --version | head -n 2'
phase_done

phase_start "complete"
echo "[ci-parity] bootstrap complete"
phase_done
exit 0
