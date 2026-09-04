#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/registry_probe.sh"
# shellcheck source=scripts/lib/registry_config.sh
source "$REPO_ROOT/scripts/lib/registry_config.sh"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CONFIG_DEST="/etc/docker/registry/config.yml"
REGISTRY_CERTS_DEST="/certs"
REGISTRY_DATA_DEST="/var/lib/registry"

if ! command -v docker >/dev/null 2>&1; then
  echo "[FAIL] docker is required to harden local registry"
  exit 2
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "[FAIL] openssl is required to generate registry htpasswd entry"
  exit 2
fi

if ! docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
  echo "[FAIL] registry container '$REGISTRY_CONTAINER' is not running"
  exit 2
fi

resolve_registry_config_path() {
  local mounted_config_path extracted_config_path
  local local_config_fallback="${REPO_ROOT}/artifacts/registry-runtime/${REGISTRY_CONTAINER}-config.yml"

  # CI pre-provisioned path: provision_ci_disposable_certs.sh writes a
  # TLS-enabled config and exports CI_REGISTRY_CONFIG.  Use it directly so we
  # do not attempt docker exec on a container that may be restarting.
  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" && -n "${CI_REGISTRY_CONFIG:-}" && -f "${CI_REGISTRY_CONFIG}" ]]; then
    echo "[registry-topology] mode=ci-pre-provisioned-config path=${CI_REGISTRY_CONFIG}" >&2
    printf '%s\n' "${CI_REGISTRY_CONFIG}"
    return 0
  fi

  # Local registry containers must restart without relying on /tmp or another
  # lifecycle-scoped mount left by an earlier bootstrap process.
  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" && -f "${local_config_fallback}" ]]; then
    echo "[registry-topology] mode=local-durable-config path=${local_config_fallback}" >&2
    printf '%s\n' "${local_config_fallback}"
    return 0
  fi

  mounted_config_path="$(docker inspect "$REGISTRY_CONTAINER" --format "{{range .Mounts}}{{if eq .Destination \"${REGISTRY_CONFIG_DEST}\"}}{{.Source}}{{end}}{{end}}")"

  if [[ -n "$mounted_config_path" && -f "$mounted_config_path" ]]; then
    if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
      mkdir -p "$(dirname "${local_config_fallback}")"
      install -m 0644 "$mounted_config_path" "${local_config_fallback}"
      echo "[registry-topology] mode=materialized-local-config path=${local_config_fallback} source=${mounted_config_path}" >&2
      printf '%s\n' "${local_config_fallback}"
      return 0
    fi
    echo "[registry-topology] mode=mounted-config path=${mounted_config_path}" >&2
    printf '%s\n' "$mounted_config_path"
    return 0
  fi

  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
    echo "[FAIL] unable to resolve mounted registry config path" >&2
    return 1
  fi

  if ! docker exec "$REGISTRY_CONTAINER" sh -c "test -f '${REGISTRY_CONFIG_DEST}'" >/dev/null 2>&1; then
    echo "[FAIL] CI registry topology missing internal config at ${REGISTRY_CONFIG_DEST}" >&2
    return 1
  fi

  extracted_config_path="${REPO_ROOT}/artifacts/registry-runtime/${REGISTRY_CONTAINER}-config.yml"
  mkdir -p "$(dirname "$extracted_config_path")"
  if ! docker exec "$REGISTRY_CONTAINER" sh -c "cat '${REGISTRY_CONFIG_DEST}'" > "$extracted_config_path"; then
    echo "[FAIL] CI registry topology could not extract ${REGISTRY_CONFIG_DEST} from ${REGISTRY_CONTAINER}" >&2
    return 1
  fi

  if [[ ! -s "$extracted_config_path" ]]; then
    echo "[FAIL] CI registry topology produced empty config at ${extracted_config_path}" >&2
    return 1
  fi
  if ! grep -Eq '^http:' "$extracted_config_path"; then
    echo "[FAIL] CI registry config missing http section: ${extracted_config_path}" >&2
    return 1
  fi
  if ! grep -Eq 'rootdirectory:[[:space:]]*/var/lib/registry' "$extracted_config_path"; then
    echo "[FAIL] CI registry config missing filesystem rootdirectory=/var/lib/registry: ${extracted_config_path}" >&2
    return 1
  fi

  echo "[registry-topology] mode=ci-container-config path=${extracted_config_path} source=${REGISTRY_CONFIG_DEST}" >&2
  printf '%s\n' "$extracted_config_path"
}

resolve_registry_certs_dir() {
  local mounted_certs_dir extracted_certs_dir cert_files cert_file

  # CI pre-provisioned path: provision_ci_disposable_certs.sh writes cert+key
  # to CI_REGISTRY_CERTS_DIR on local disk.  Use it directly.
  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" && -n "${CI_REGISTRY_CERTS_DIR:-}" && -d "${CI_REGISTRY_CERTS_DIR}" ]]; then
    if ls "${CI_REGISTRY_CERTS_DIR}/"*.crt >/dev/null 2>&1 && ls "${CI_REGISTRY_CERTS_DIR}/"*.key >/dev/null 2>&1; then
      echo "[registry-topology] mode=ci-pre-provisioned-certs dir=${CI_REGISTRY_CERTS_DIR}" >&2
      printf '%s\n' "${CI_REGISTRY_CERTS_DIR}"
      return 0
    fi
    echo "[FAIL] CI_REGISTRY_CERTS_DIR set but missing .crt or .key files: ${CI_REGISTRY_CERTS_DIR}" >&2
    return 1
  fi

  mounted_certs_dir="$(docker inspect "$REGISTRY_CONTAINER" --format "{{range .Mounts}}{{if eq .Destination \"${REGISTRY_CERTS_DEST}\"}}{{.Source}}{{end}}{{end}}")"

  if [[ -n "$mounted_certs_dir" && -d "$mounted_certs_dir" ]]; then
    echo "[registry-topology] mode=mounted-certs dir=${mounted_certs_dir}" >&2
    printf '%s\n' "$mounted_certs_dir"
    return 0
  fi

  # Local workspace artifact fallback: when the mounted certs path is
  # unreadable (stale CI-runner container), fall back to local artifacts.
  local local_certs_fallback="${REPO_ROOT}/artifacts/registry-certs-ci"
  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
    if ls "${local_certs_fallback}/"*.crt >/dev/null 2>&1 && ls "${local_certs_fallback}/"*.key >/dev/null 2>&1; then
      echo "[registry-topology] mode=local-artifact-certs dir=${local_certs_fallback}" >&2
      printf '%s\n' "${local_certs_fallback}"
      return 0
    fi
    echo "[FAIL] unable to resolve mounted registry cert directory" >&2
    return 1
  fi

  if ! docker exec "$REGISTRY_CONTAINER" sh -c "test -d '${REGISTRY_CERTS_DEST}'" >/dev/null 2>&1; then
    echo "[FAIL] CI registry topology missing internal certs at ${REGISTRY_CERTS_DEST}" >&2
    return 1
  fi

  extracted_certs_dir="${REPO_ROOT}/artifacts/registry-runtime/${REGISTRY_CONTAINER}-certs"
  mkdir -p "$extracted_certs_dir"

  mapfile -t cert_files < <(docker exec "$REGISTRY_CONTAINER" sh -c "ls '${REGISTRY_CERTS_DEST}'" 2>/dev/null)
  if [[ ${#cert_files[@]} -eq 0 ]]; then
    echo "[FAIL] CI registry topology found empty certs directory at ${REGISTRY_CERTS_DEST}" >&2
    return 1
  fi

  for cert_file in "${cert_files[@]}"; do
    [[ -n "$cert_file" ]] || continue
    if ! docker exec "$REGISTRY_CONTAINER" sh -c "cat '${REGISTRY_CERTS_DEST}/${cert_file}'" > "${extracted_certs_dir}/${cert_file}"; then
      echo "[FAIL] CI registry topology could not extract ${cert_file} from ${REGISTRY_CONTAINER}" >&2
      return 1
    fi
  done

  # Validate TLS cert and key are present
  if ! ls "${extracted_certs_dir}/"*.crt >/dev/null 2>&1 || ! ls "${extracted_certs_dir}/"*.key >/dev/null 2>&1; then
    echo "[FAIL] CI registry topology missing TLS cert or key in ${extracted_certs_dir}" >&2
    return 1
  fi

  echo "[registry-topology] mode=ci-container-certs dir=${extracted_certs_dir} source=${REGISTRY_CERTS_DEST}" >&2
  printf '%s\n' "$extracted_certs_dir"
}

resolve_registry_data_mount() {
  local mounted_data
  mounted_data="$(docker inspect "$REGISTRY_CONTAINER" --format "{{range .Mounts}}{{if eq .Destination \"${REGISTRY_DATA_DEST}\"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}")"

  if [[ -n "$mounted_data" ]]; then
    printf '%s\n' "$mounted_data"
    return 0
  fi

  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
    echo "[FAIL] unable to resolve registry data mount" >&2
    return 1
  fi

  # In CI disposable mode create a named volume to persist registry data across the hardening restart
  local ci_data_volume="${REGISTRY_CONTAINER}-data-ci"
  docker volume create "$ci_data_volume" >/dev/null 2>&1 || true
  echo "[registry-topology] mode=ci-data-volume volume=${ci_data_volume}" >&2
  printf '%s\n' "$ci_data_volume"
}

config_path="$(resolve_registry_config_path)"
certs_dir="$(resolve_registry_certs_dir)"
data_mount="$(resolve_registry_data_mount)"
kind_alias="$(docker inspect "$REGISTRY_CONTAINER" --format '{{with index .NetworkSettings.Networks "kind"}}{{range .Aliases}}{{println .}}{{end}}{{end}}' | awk 'NF' | head -n1)"

if [[ -z "$config_path" || ! -f "$config_path" ]]; then
  echo "[FAIL] unable to resolve verified registry config path"
  exit 2
fi
if [[ -z "$certs_dir" || ! -d "$certs_dir" ]]; then
  echo "[FAIL] unable to resolve registry cert directory"
  exit 2
fi
if [[ -z "$data_mount" ]]; then
  echo "[FAIL] unable to resolve registry data mount"
  exit 2
fi
if ! registry_config_validate "$config_path" "$certs_dir" "$REGISTRY_PORT" >/dev/null; then
  echo "[FAIL] REGISTRY_CONFIG_INVALID: refusing to mount unvalidated registry configuration" >&2
  exit 2
fi
echo "[registry-topology] REGISTRY_CONFIG_VALIDATED=true" >&2

wait_for_container_absent() {
  local name="$1"
  local timeout_seconds="${2:-45}"
  local elapsed=0
  while docker inspect "$name" >/dev/null 2>&1; do
    if (( elapsed >= timeout_seconds )); then
      echo "[FAIL] registry container '$name' did not disappear within ${timeout_seconds}s"
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 0
}

remove_registry_container_safely() {
  local name="$1"
  local attempts=0
  local max_attempts=5
  while (( attempts < max_attempts )); do
    attempts=$((attempts + 1))
    if ! docker inspect "$name" >/dev/null 2>&1; then
      return 0
    fi

    local rm_output=""
    rm_output="$(docker rm -f "$name" 2>&1)" || true

    if [[ -n "$rm_output" ]] && [[ "$rm_output" != "$name" ]]; then
      # Docker may transiently report this when a previous delete is still finalizing.
      if [[ "$rm_output" == *"already in progress"* ]]; then
        sleep 1
      elif [[ "$rm_output" == *"No such container"* ]]; then
        return 0
      else
        echo "[FAIL] unable to remove registry container '$name': $rm_output"
        return 1
      fi
    fi

    if wait_for_container_absent "$name" 45; then
      return 0
    fi
  done

  echo "[FAIL] unable to remove registry container '$name' after ${max_attempts} attempts"
  return 1
}

run_registry_container_safely() {
  local attempts=0
  local max_attempts=5
  while (( attempts < max_attempts )); do
    attempts=$((attempts + 1))
    local run_output=""
    run_output="$(docker run -d --restart=always -p "${REGISTRY_PORT}:${REGISTRY_PORT}" \
      --name "$REGISTRY_CONTAINER" \
      -e REGISTRY_STORAGE_DELETE_ENABLED=true \
      -e REGISTRY_AUTH=htpasswd \
      -e REGISTRY_AUTH_HTPASSWD_REALM=threadforge-registry \
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/registry.htpasswd \
      -v "$config_path:/etc/docker/registry/config.yml:ro" \
      -v "$certs_dir:/certs:ro" \
      -v "$htpasswd_file:/auth/registry.htpasswd:ro" \
      -v "$data_mount:/var/lib/registry" \
      registry:2 2>&1)" || true

    if docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "$run_output" == *"is already in use by container"* ]] || [[ "$run_output" == *"removal of container"*"already in progress"* ]]; then
      sleep 1
      continue
    fi

    echo "[FAIL] unable to start hardened registry container '$REGISTRY_CONTAINER': ${run_output:-unknown docker run error}"
    return 1
  done

  echo "[FAIL] unable to start hardened registry container '$REGISTRY_CONTAINER' after ${max_attempts} attempts"
  return 1
}

reconcile_registry_dns() {
  local registry_ipv4 current_corefile updated_corefile

  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl get configmap coredns -n kube-system >/dev/null 2>&1 || return 0

  registry_ipv4="$(docker inspect "$REGISTRY_CONTAINER" \
    --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
  [[ -n "$registry_ipv4" ]] || return 1

  current_corefile="$(kubectl get configmap coredns -n kube-system -o json)"
  updated_corefile="$(printf '%s' "$current_corefile" | jq --arg ip "$registry_ipv4" --arg host "$REGISTRY_ALIAS" \
    '.data.Corefile |= sub("(?m)^[[:space:]]*[0-9.]+[[:space:]]+" + $host + "[[:space:]]*$"; "           " + $ip + " " + $host)')"
  printf '%s' "$updated_corefile" | kubectl apply -f - >/dev/null
  kubectl rollout restart deployment/coredns -n kube-system >/dev/null
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s >/dev/null
}

auth_dir="${REGISTRY_AUTH_DIR:-$REPO_ROOT/artifacts/registry-auth}"
mkdir -p "$auth_dir"
htpasswd_file="$auth_dir/registry.htpasswd"
python3 - "$REGISTRY_USER" "$REGISTRY_PASSWORD" > "$htpasswd_file" <<'PY'
import bcrypt
import sys

user = sys.argv[1]
password = sys.argv[2].encode("utf-8")
hashed = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12)).decode("utf-8")
print(f"{user}:{hashed}")
PY
chmod 600 "$htpasswd_file"

remove_registry_container_safely "$REGISTRY_CONTAINER"
run_registry_container_safely

if docker network inspect kind >/dev/null 2>&1; then
  docker network connect --alias "${kind_alias:-$REGISTRY_ALIAS}" kind "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
fi

registry_ipv4="$(docker inspect "$REGISTRY_CONTAINER" \
  --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
[[ -n "$registry_ipv4" ]] || {
  echo "[FAIL] unable to resolve registry container IPv4 address"
  exit 2
}

reconcile_registry_dns
registry_probe_reconcile_host_dns "$REGISTRY_ALIAS" "$REGISTRY_CONTAINER"

unauth_code="$(registry_probe_anonymous_status "$REGISTRY_ALIAS" "$REGISTRY_PORT")"
if [[ "$unauth_code" != "401" && "$unauth_code" != "403" ]]; then
  echo "[FAIL] registry anonymous access still permitted (HTTP ${unauth_code:-000})"
  exit 2
fi

auth_code="$(registry_probe_authenticated_status "$REGISTRY_ALIAS" "$REGISTRY_PORT" "$REGISTRY_USER" "$REGISTRY_PASSWORD")"
if [[ "$auth_code" != "200" ]]; then
  echo "[FAIL] registry authenticated API probe failed (HTTP ${auth_code:-000})"
  exit 2
fi

# Recreate the host-network BuildKit consumer after registry recreation so its
# container-local DNS and endpoint state cannot retain the old registry IP.
if [[ "${THREADFORGE_SKIP_BUILDER_SETUP:-0}" != "1" && -x "$REPO_ROOT/scripts/build/setup_builder.sh" ]]; then
  bash "$REPO_ROOT/scripts/build/setup_builder.sh"
fi

echo "[PASS] local registry hardened (anonymous disabled; authenticated API enabled)"
