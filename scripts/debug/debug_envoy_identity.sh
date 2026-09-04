#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

OUT_PATH="${1:-$REPO_ROOT/artifacts/debug/envoy_identity_debug.log}"
REAL_KUBECTL="$(type -P kubectl || true)"

if [ -z "$REAL_KUBECTL" ]; then
  echo "[FAIL] kubectl not found" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT_PATH")"

python3 - "$OUT_PATH" "$REAL_KUBECTL" "$SPIFFE_TRUST_DOMAIN" <<'PY'
import json
import pathlib
import subprocess
import sys

out_path = pathlib.Path(sys.argv[1])
kubectl = sys.argv[2]
trust_domain = sys.argv[3]

targets = [
    {
        "namespace": "threadforge-test",
        "deployment": "echo",
        "exec_target": "deploy/echo",
    },
    {
        "namespace": "istio-system",
        "deployment": "istio-ingressgateway",
        "exec_target": "deploy/istio-ingressgateway",
    },
]


def run(*args):
    return subprocess.check_output(args, text=True)


def selector_arg(match_labels):
    parts = []
    for key, value in sorted(match_labels.items()):
        parts.append(f"{key}={value}")
    return ",".join(parts)


def resolve_pod(target):
    deploy = json.loads(
        run(kubectl, "-n", target["namespace"], "get", "deploy", target["deployment"], "-o", "json")
    )
    selector = deploy.get("spec", {}).get("selector", {}).get("matchLabels", {})
    if not isinstance(selector, dict) or not selector:
        raise RuntimeError(f"deployment {target['namespace']}/{target['deployment']} has no selector")

    pods = json.loads(
        run(
            kubectl,
            "-n",
            target["namespace"],
            "get",
            "pods",
            "-l",
            selector_arg(selector),
            "-o",
            "json",
        )
    )

    items = pods.get("items", []) if isinstance(pods, dict) else []
    running = []
    for pod in items:
        if not isinstance(pod, dict):
            continue
        if pod.get("metadata", {}).get("deletionTimestamp"):
            continue
        if pod.get("status", {}).get("phase") != "Running":
            continue
        names = [c.get("name") for c in pod.get("spec", {}).get("containers", []) if isinstance(c, dict)]
        if "istio-proxy" not in names:
            continue
        running.append(pod)

    if not running:
        raise RuntimeError(f"no running pod with istio-proxy found for {target['namespace']}/{target['deployment']}")

    pod = running[0]
    service_account = pod.get("spec", {}).get("serviceAccountName") or "default"
    return {
        "pod_name": pod.get("metadata", {}).get("name", ""),
        "namespace": target["namespace"],
        "service_account": service_account,
        "expected_san": f"spiffe://{trust_domain}/ns/{target['namespace']}/sa/{service_account}",
    }


def parse_cert_dump(raw):
    doc = json.loads(raw)
    extracted = []
    for cert in doc.get("certificates", []):
        if not isinstance(cert, dict):
            continue
        issuers = []
        for ca in cert.get("ca_cert", []) or []:
            if not isinstance(ca, dict):
                continue
            for san in ca.get("subject_alt_names", []) or []:
                if isinstance(san, dict) and isinstance(san.get("uri"), str) and san.get("uri"):
                    issuers.append(san["uri"])
        issuer = issuers[0] if issuers else ""
        for leaf in cert.get("cert_chain", []) or []:
            if not isinstance(leaf, dict):
                continue
            serial = leaf.get("serial_number", "")
            for san in leaf.get("subject_alt_names", []) or []:
                if not isinstance(san, dict):
                    continue
                uri = san.get("uri")
                if isinstance(uri, str) and uri.startswith("spiffe://"):
                    extracted.append(
                        {
                            "spiffe_san": uri,
                            "issuer": issuer,
                            "serial": serial,
                        }
                    )

    unique = []
    seen = set()
    for item in extracted:
        key = (item["spiffe_san"], item["issuer"], item["serial"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique


pods_wide = run(kubectl, "get", "pods", "-A", "-o", "wide")
sections = ["=== target pods ===", pods_wide.rstrip(), ""]

for target in targets:
    pod_info = resolve_pod(target)
    cert_dump = run(
        kubectl,
        "exec",
        "-n",
        target["namespace"],
        target["exec_target"],
        "-c",
        "istio-proxy",
        "--",
        "curl",
        "-s",
        "localhost:15000/certs",
    )
    extracted = parse_cert_dump(cert_dump)
    sections.extend(
        [
            f"=== workload: {target['namespace']}/{target['deployment']} ===",
            f"pod: {pod_info['pod_name']}",
            f"namespace: {pod_info['namespace']}",
            f"service account: {pod_info['service_account']}",
            f"expected SPIFFE SAN: {pod_info['expected_san']}",
            "extracted SANs:",
            json.dumps(extracted, indent=2),
            "cert dump:",
            cert_dump.rstrip(),
            "",
        ]
    )

out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text("\n".join(sections) + "\n")
print(f"[PASS] wrote {out_path}")
PY
