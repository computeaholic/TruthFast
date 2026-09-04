#!/usr/bin/env bash

emit_missing_prereq() {
  printf "[FAIL] MISSING_PREREQ: %s\n" "$1"
  printf "[FAIL] Run 'make infra-bootstrap' before 'make proof'\n"
  exit 10
}

_normalize_semver() {
  python3 - "$1" <<'PY'
import re
import sys

raw = (sys.argv[1] or "").strip()
match = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", raw)
if not match:
    raise SystemExit(1)
major, minor, patch = match.groups()
print(f"{int(major)}.{int(minor)}.{int(patch or 0)}")
PY
}

_minor_version() {
  python3 - "$1" <<'PY'
import re
import sys

raw = (sys.argv[1] or "").strip()
match = re.search(r"(\d+)\.(\d+)", raw)
if not match:
    raise SystemExit(1)
print(f"{int(match.group(1))}.{int(match.group(2))}")
PY
}

detect_k8s_server_version() {
  local version_json version

  version_json="$(proof_prereq_kubectl version -o json 2>/dev/null)" || return 1
  version="$(python3 - "$version_json" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
server = doc.get("serverVersion") or {}
git_version = server.get("gitVersion") or ""
if not git_version:
    raise SystemExit(1)
print(git_version)
PY
)" || return 1

  _normalize_semver "$version"
}

detect_istio_version() {
  local version

  version="$(proof_prereq_kubectl get deploy istiod -n istio-system -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
  if [ -n "$version" ]; then
    _normalize_semver "$version"
    return 0
  fi

  version="${THREADFORGE_EXPECTED_ISTIO_VERSION:-${ISTIO_TAG:-}}"
  if [ -n "$version" ]; then
    _normalize_semver "$version"
    return 0
  fi

  if command -v istioctl >/dev/null 2>&1; then
    version="$(istioctl version --remote=false 2>/dev/null | awk '/^client version:/ {print $3; exit}' || true)"
    if [ -n "$version" ]; then
      _normalize_semver "$version"
      return 0
    fi
  fi

  return 1
}

require_supported_k8s_istio_combo_or_fail() {
  local k8s_version istio_version k8s_minor istio_minor supported=false

  k8s_version="$(detect_k8s_server_version)" || emit_missing_prereq "unable to detect Kubernetes server version"
  istio_version="$(detect_istio_version)" || emit_missing_prereq "unable to detect Istio version"
  k8s_minor="$(_minor_version "$k8s_version")" || emit_missing_prereq "unable to parse Kubernetes server version"
  istio_minor="$(_minor_version "$istio_version")" || emit_missing_prereq "unable to parse Istio version"

  case "$k8s_minor:$istio_minor" in
    1.30:1.29)
      supported=true
      ;;
  esac

  if [ "$supported" != "true" ]; then
    printf "[FAIL] MISSING_PREREQ: unsupported k8s/istio version combination\n"
    printf "[FAIL] detected k8s=%s istio=%s\n" "$k8s_version" "$istio_version"
    exit 10
  fi

  printf "[PASS] k8s/istio compatibility verified (k8s=%s, istio=%s)\n" "$k8s_version" "$istio_version"
}

proof_prereq_kubectl() {
  if command -v run_real_kubectl >/dev/null 2>&1; then
    run_real_kubectl "$@"
  else
    kubectl "$@"
  fi
}

proof_job_uid_or_fail() {
  local namespace="$1"
  local job_name="$2"
  local job_json job_json_file job_uid

  job_json="$(proof_prereq_kubectl get job -n "$namespace" "$job_name" -o json 2>/dev/null)" \
    || return 1

  job_json_file="$(mktemp)"
  printf '%s' "$job_json" >"$job_json_file"
  if ! job_uid="$(python3 - "$job_name" "$job_json_file" <<'PY'
import json
import sys

job_name = sys.argv[1]
job_json_path = sys.argv[2]
with open(job_json_path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)
metadata = doc.get("metadata") or {}
uid = str(metadata.get("uid") or "").strip()
name = str(metadata.get("name") or "").strip()
if not uid or name != job_name:
    raise SystemExit(1)
print(uid)
PY
)"; then
    local rc=$?
    rm -f "$job_json_file"
    return "$rc"
  fi
  rm -f "$job_json_file"

  printf '%s\n' "$job_uid"
  return 0
}

proof_owned_pod_for_job_uid_or_fail() {
  local namespace="$1"
  local job_name="$2"
  local job_uid="$3"
  local pods_json pods_json_file

  pods_json="$(proof_prereq_kubectl get pods -n "$namespace" -o json 2>/dev/null)" \
    || return 1

  pods_json_file="$(mktemp)"
  printf '%s' "$pods_json" >"$pods_json_file"
  if ! python3 - "$job_name" "$job_uid" "$pods_json_file" <<'PY'
import json
import sys

job_name = sys.argv[1]
job_uid = sys.argv[2]
pods_json_path = sys.argv[3]
with open(pods_json_path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)
matches = []

for pod in doc.get("items") or []:
    metadata = pod.get("metadata") or {}
    owner_refs = metadata.get("ownerReferences") or []
    for ref in owner_refs:
        if ref.get("kind") == "Job" and ref.get("name") == job_name and ref.get("uid") == job_uid:
            matches.append(
                (
                    str(metadata.get("name") or "").strip(),
                    str(metadata.get("uid") or "").strip(),
                    str(metadata.get("creationTimestamp") or "").strip(),
                )
            )
            break

if not matches:
    raise SystemExit(1)
if len(matches) != 1:
    raise SystemExit(2)

print("\t".join(matches[0]))
PY
  then
    local rc=$?
    rm -f "$pods_json_file"
    return "$rc"
  fi
  rm -f "$pods_json_file"
}

require_cluster_reachable_or_missing_prereq() {
  proof_prereq_kubectl cluster-info >/dev/null 2>&1 || emit_missing_prereq "$1"
}

require_nodes_present_or_missing_prereq() {
  proof_prereq_kubectl get nodes --no-headers 2>/dev/null | grep -q . || emit_missing_prereq "$1"
}

require_nodes_ready_or_missing_prereq() {
  proof_prereq_kubectl wait --for=condition=Ready nodes --all --timeout="${2:-30s}" >/dev/null 2>&1 \
    || emit_missing_prereq "$1"
}

require_namespace_or_missing_prereq() {
  proof_prereq_kubectl get ns "$1" >/dev/null 2>&1 || emit_missing_prereq "$2"
}

require_deployment_or_missing_prereq() {
  proof_prereq_kubectl get deploy -n "$1" "$2" >/dev/null 2>&1 || emit_missing_prereq "$3"
}

require_service_or_missing_prereq() {
  proof_prereq_kubectl get svc -n "$1" "$2" >/dev/null 2>&1 || emit_missing_prereq "$3"
}

require_endpoints_or_missing_prereq() {
  proof_prereq_kubectl get endpoints "$2" -n "$1" -o jsonpath='{.subsets}' 2>/dev/null | grep -q . \
    || emit_missing_prereq "$3"
}

require_namespace_pods_or_missing_prereq() {
  proof_prereq_kubectl get pods -n "$1" >/dev/null 2>&1 || emit_missing_prereq "$2"
}

require_file_or_missing_prereq() {
  [ -f "$1" ] || emit_missing_prereq "$2"
}

require_command_or_missing_prereq() {
  command -v "$1" >/dev/null 2>&1 || emit_missing_prereq "$2"
}

require_registry_healthy_or_missing_prereq() {
  bash scripts/verify/registry_health.sh >/dev/null || emit_missing_prereq "$1"
}

require_spire_server_ready_or_missing_prereq() {
  spire_json="$(proof_prereq_kubectl get pods -n spire-system -l app=spire-server -o json 2>/dev/null)" \
    || emit_missing_prereq "$1"

  python3 - "$spire_json" <<'PY' >/dev/null 2>&1 || emit_missing_prereq "$1"
import json
import sys

doc = json.loads(sys.argv[1])
items = doc.get("items") or []
if not items:
    raise SystemExit(1)

def ready_condition(pod: dict) -> bool:
    for condition in pod.get("status", {}).get("conditions") or []:
        if condition.get("type") == "Ready" and condition.get("status") == "True":
            return True
    return False

def spire_container_ready(pod: dict) -> bool:
    for container in pod.get("status", {}).get("containerStatuses") or []:
        if container.get("name") == "spire-server" and container.get("ready") is True:
            return True
    return False

if not any(ready_condition(pod) and spire_container_ready(pod) for pod in items):
    raise SystemExit(1)
PY
}
