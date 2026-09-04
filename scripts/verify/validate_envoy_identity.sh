#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

OUT_PATH="$REPO_ROOT/artifacts/envoy_identity_validation.json"
DEBUG_PATH="$REPO_ROOT/artifacts/debug/envoy_identity_debug.log"
FAILURE_PATH="$REPO_ROOT/artifacts/debug/envoy_identity_failure.log"
DEBUG_SCRIPT="$REPO_ROOT/scripts/debug/debug_envoy_identity.sh"
REAL_KUBECTL="$(type -P kubectl || true)"

if [ -z "$REAL_KUBECTL" ]; then
  echo "[FAIL] kubectl not found"
  exit 2
fi

if [ ! -x "$DEBUG_SCRIPT" ]; then
  echo "[FAIL] missing executable debug script: scripts/debug/debug_envoy_identity.sh"
  exit 2
fi

mkdir -p "$REPO_ROOT/artifacts/debug"
"$DEBUG_SCRIPT" "$DEBUG_PATH" >/dev/null 2>&1 || true

python3 - "$OUT_PATH" "$FAILURE_PATH" "$REAL_KUBECTL" "$SPIFFE_TRUST_DOMAIN" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import time

out_path = pathlib.Path(sys.argv[1])
failure_path = pathlib.Path(sys.argv[2])
kubectl = sys.argv[3]
trust_domain = sys.argv[4]

traffic_probe = {
    "source_namespace": "threadforge-test",
    "source_deployment": "test-client",
    "source_app_container": "test-client",
    "destination_namespace": "threadforge-test",
    "destination_deployment": "echo",
    "destination_app_container": "echo",
    "target_url": "http://echo.threadforge-test.svc.cluster.local/healthz",
}


def run(*args, check=True):
    proc = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, args, proc.stdout, proc.stderr)
    return proc


def selector_arg(match_labels):
    parts = []
    for key, value in sorted(match_labels.items()):
        parts.append(f"{key}={value}")
    return ",".join(parts)


def resolve_pod(target):
    deploy = json.loads(
        run(kubectl, "-n", target["namespace"], "get", "deploy", target["deployment"], "-o", "json").stdout
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
        ).stdout
    )

    items = pods.get("items", []) if isinstance(pods, dict) else []
    candidates = []
    for pod in items:
        if not isinstance(pod, dict):
            continue
        if pod.get("metadata", {}).get("deletionTimestamp"):
            continue
        if pod.get("status", {}).get("phase") != "Running":
            continue
        conditions = pod.get("status", {}).get("conditions") or []
        ready = any(
            isinstance(condition, dict)
            and condition.get("type") == "Ready"
            and condition.get("status") == "True"
            for condition in conditions
        )
        if not ready:
            continue
        containers = [c.get("name") for c in pod.get("spec", {}).get("containers", []) if isinstance(c, dict)]
        if "istio-proxy" not in containers:
            continue
        candidates.append(pod)

    if not candidates:
        raise RuntimeError(f"no running pod with istio-proxy found for {target['namespace']}/{target['deployment']}")

    pod = candidates[0]
    service_account = pod.get("spec", {}).get("serviceAccountName") or "default"
    return {
        "workload": target["deployment"],
        "pod": pod.get("metadata", {}).get("name", ""),
        "namespace": target["namespace"],
        "service_account": service_account,
        "expected_spiffe_id": f"spiffe://{trust_domain}/ns/{target['namespace']}/sa/{service_account}",
    }


def parse_cert_dump(raw):
    try:
        doc = json.loads(raw)
    except Exception as exc:
        return [], [f"invalid cert dump JSON: {exc}"]

    certificates = doc.get("certificates")
    if not isinstance(certificates, list) or not certificates:
        return [], ["no certs"]

    entries = []
    for cert in certificates:
        if not isinstance(cert, dict):
            continue
        issuer_uris = []
        for ca in cert.get("ca_cert", []) or []:
            if not isinstance(ca, dict):
                continue
            for san in ca.get("subject_alt_names", []) or []:
                if isinstance(san, dict) and isinstance(san.get("uri"), str) and san.get("uri"):
                    issuer_uris.append(san["uri"])
        issuer = issuer_uris[0] if issuer_uris else ""

        for leaf in cert.get("cert_chain", []) or []:
            if not isinstance(leaf, dict):
                continue
            serial = leaf.get("serial_number", "")
            for san in leaf.get("subject_alt_names", []) or []:
                if not isinstance(san, dict):
                    continue
                uri = san.get("uri")
                if isinstance(uri, str) and uri.startswith("spiffe://"):
                    entries.append(
                        {
                            "spiffe_san": uri,
                            "issuer": issuer,
                            "serial": serial,
                        }
                    )

    unique = []
    seen = set()
    for entry in entries:
        key = (entry["spiffe_san"], entry["issuer"], entry["serial"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(entry)

    if not unique:
        return [], ["no SPIFFE SAN"]
    return unique, []


def extract_log_spiffe_ids(raw):
    matches = re.findall(r"spiffe://[A-Za-z0-9._/-]+", raw)
    return sorted(set(matches))


def fetch_proxy_log(namespace, pod):
    proc = run(
        kubectl,
        "logs",
        "-n",
        namespace,
        pod,
        "-c",
        "istio-proxy",
        "--since=5m",
        "--tail=400",
        check=False,
    )
    if proc.returncode != 0:
        return "", f"kubectl logs failed: {proc.stderr.strip() or proc.stdout.strip() or proc.returncode}"
    return proc.stdout, ""


def summarize_proxy_identity(info, cert_dump, log_dump):
    extracted, errors = parse_cert_dump(cert_dump)
    observed_spiffe_ids = sorted({item["spiffe_san"] for item in extracted})
    serials = sorted({item["serial"] for item in extracted if item["serial"]})
    issuers = sorted({item["issuer"] for item in extracted if item["issuer"]})
    log_spiffe_ids = extract_log_spiffe_ids(log_dump)
    return {
        "workload": info["workload"],
        "namespace": info["namespace"],
        "pod": info["pod"],
        "service_account": info["service_account"],
        "expected_spiffe_id": info["expected_spiffe_id"],
        "observed_spiffe_ids": observed_spiffe_ids,
        "serials": serials,
        "issuers": issuers,
        "proxy_log_spiffe_ids": log_spiffe_ids,
        "cert_errors": errors,
        "cert_dump": cert_dump,
        "proxy_log": log_dump,
    }


connections = []
failures = []

connection = {
    "name": "test-client->echo",
    "source": {},
    "destination": {},
    "traffic": {
        "url": traffic_probe["target_url"],
        "http_status": "000",
        "status": "FAIL",
        "message": "",
        "trace": "",
    },
    "status": "FAIL",
    "message": "",
}

try:
    source_info = resolve_pod(
        {
            "namespace": traffic_probe["source_namespace"],
            "deployment": traffic_probe["source_deployment"],
        }
    )
    destination_info = resolve_pod(
        {
            "namespace": traffic_probe["destination_namespace"],
            "deployment": traffic_probe["destination_deployment"],
        }
    )

    trace_proc = run(
        kubectl,
        "exec",
        "-n",
        source_info["namespace"],
        source_info["pod"],
        "-c",
        traffic_probe["source_app_container"],
        "--",
        "curl",
        "-sv",
        "--max-time",
        "10",
        traffic_probe["target_url"],
        check=False,
    )
    status_proc = run(
        kubectl,
        "exec",
        "-n",
        source_info["namespace"],
        source_info["pod"],
        "-c",
        traffic_probe["source_app_container"],
        "--",
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "--max-time",
        "10",
        traffic_probe["target_url"],
        check=False,
    )
    http_status = (status_proc.stdout or "000").strip()[:3] or "000"
    connection["traffic"]["trace"] = (trace_proc.stderr or trace_proc.stdout or "").strip()
    connection["traffic"]["http_status"] = http_status
    if http_status == "200":
        connection["traffic"]["status"] = "PASS"
        connection["traffic"]["message"] = "live in-mesh request succeeded"
    else:
        connection["traffic"]["message"] = f"live in-mesh request failed with HTTP {http_status}"

    source_cert_proc = run(
        kubectl,
        "exec",
        "-n",
        source_info["namespace"],
        source_info["pod"],
        "-c",
        "istio-proxy",
        "--",
        "curl",
        "-sS",
        "localhost:15000/certs",
    )
    destination_cert_proc = run(
        kubectl,
        "exec",
        "-n",
        destination_info["namespace"],
        destination_info["pod"],
        "-c",
        "istio-proxy",
        "--",
        "curl",
        "-sS",
        "localhost:15000/certs",
    )
    # wait for Envoy access log to flush — access log entries with mTLS peer SANs
    # (which carry spiffe:// URIs) take ~1-2s to appear in kubectl logs
    time.sleep(2)
    source_log_dump, source_log_error = fetch_proxy_log(source_info["namespace"], source_info["pod"])
    destination_log_dump, destination_log_error = fetch_proxy_log(destination_info["namespace"], destination_info["pod"])

    source_summary = summarize_proxy_identity(source_info, source_cert_proc.stdout, source_log_dump)
    destination_summary = summarize_proxy_identity(destination_info, destination_cert_proc.stdout, destination_log_dump)
    if source_log_error:
        source_summary["log_error"] = source_log_error
    if destination_log_error:
        destination_summary["log_error"] = destination_log_error
    connection["source"] = source_summary
    connection["destination"] = destination_summary

    problems = []
    for side, summary in (("source", source_summary), ("destination", destination_summary)):
        if summary["cert_errors"]:
            problems.append(f"{side} proxy /certs missing SPIFFE SAN evidence")
        elif summary["observed_spiffe_ids"] != [summary["expected_spiffe_id"]]:
            problems.append(f"{side} Envoy SPIFFE SAN does not exactly match expected workload identity")
        if any(not san.startswith(f"spiffe://{trust_domain}/") for san in summary["observed_spiffe_ids"]):
            problems.append(f"{side} Envoy SPIFFE SAN is outside trust domain")

    combined_log_ids = sorted(set(source_summary["proxy_log_spiffe_ids"] + destination_summary["proxy_log_spiffe_ids"]))
    expected_log_ids = {source_summary["expected_spiffe_id"], destination_summary["expected_spiffe_id"]}
    if connection["traffic"]["status"] != "PASS":
        problems.append(connection["traffic"]["message"])
    if not expected_log_ids.intersection(combined_log_ids):
        problems.append("proxy logs do not expose workload SPIFFE IDs after live traffic")

    if problems:
        connection["message"] = "; ".join(problems)
    else:
        connection["status"] = "PASS"
        connection["message"] = "live traffic succeeded and Envoy logs + /certs proved exact workload SPIFFE identities"
except subprocess.CalledProcessError as exc:
    connection["message"] = f"kubectl command failed: {exc.stderr.strip() or exc.stdout.strip() or exc}"
except Exception as exc:
    connection["message"] = str(exc)

connections.append(connection)
if connection["status"] != "PASS":
    failures.append(connection)

payload = {
    "envoy_identity": "PASS" if not failures else "FAIL",
    "identity_model": "envoy-runtime-traffic",
    "connections": [
        {
            "name": item["name"],
            "source": {
                "workload": item["source"].get("workload", ""),
                "namespace": item["source"].get("namespace", ""),
                "pod": item["source"].get("pod", ""),
                "service_account": item["source"].get("service_account", ""),
                "expected_spiffe_id": item["source"].get("expected_spiffe_id", ""),
                "observed_spiffe_ids": item["source"].get("observed_spiffe_ids", []),
                "serials": item["source"].get("serials", []),
                "issuers": item["source"].get("issuers", []),
                "proxy_log_spiffe_ids": item["source"].get("proxy_log_spiffe_ids", []),
            },
            "destination": {
                "workload": item["destination"].get("workload", ""),
                "namespace": item["destination"].get("namespace", ""),
                "pod": item["destination"].get("pod", ""),
                "service_account": item["destination"].get("service_account", ""),
                "expected_spiffe_id": item["destination"].get("expected_spiffe_id", ""),
                "observed_spiffe_ids": item["destination"].get("observed_spiffe_ids", []),
                "serials": item["destination"].get("serials", []),
                "issuers": item["destination"].get("issuers", []),
                "proxy_log_spiffe_ids": item["destination"].get("proxy_log_spiffe_ids", []),
            },
            "traffic": {
                "url": item["traffic"].get("url", ""),
                "http_status": item["traffic"].get("http_status", "000"),
                "status": item["traffic"].get("status", "FAIL"),
                "message": item["traffic"].get("message", ""),
            },
            "status": item["status"],
            "message": item["message"],
        }
        for item in connections
    ],
    "summary": {
        "failures": len(failures),
        "traffic_proven": any(item["traffic"]["status"] == "PASS" for item in connections),
        "spiffe_log_evidence": any(
            bool(item["source"].get("proxy_log_spiffe_ids") or item["destination"].get("proxy_log_spiffe_ids"))
            for item in connections
        ),
    },
}

out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2) + "\n")

if failures:
    lines = []
    for failure in failures:
        lines.extend(
            [
                f"=== connection: {failure['name']} ===",
                f"message: {failure['message']}",
                f"traffic_url: {failure['traffic']['url']}",
                f"traffic_status: {failure['traffic']['http_status']}",
                f"traffic_message: {failure['traffic']['message']}",
                "traffic trace:",
                failure["traffic"]["trace"].rstrip(),
                "",
                "source summary:",
                json.dumps({
                    "workload": failure["source"].get("workload", ""),
                    "namespace": failure["source"].get("namespace", ""),
                    "pod": failure["source"].get("pod", ""),
                    "service_account": failure["source"].get("service_account", ""),
                    "expected_spiffe_id": failure["source"].get("expected_spiffe_id", ""),
                    "observed_spiffe_ids": failure["source"].get("observed_spiffe_ids", []),
                    "serials": failure["source"].get("serials", []),
                    "issuers": failure["source"].get("issuers", []),
                    "proxy_log_spiffe_ids": failure["source"].get("proxy_log_spiffe_ids", []),
                    "cert_errors": failure["source"].get("cert_errors", []),
                    "log_error": failure["source"].get("log_error", ""),
                }, indent=2),
                "source cert dump:",
                failure["source"].get("cert_dump", "").rstrip(),
                "source proxy log:",
                failure["source"].get("proxy_log", "").rstrip(),
                "",
                "destination summary:",
                json.dumps({
                    "workload": failure["destination"].get("workload", ""),
                    "namespace": failure["destination"].get("namespace", ""),
                    "pod": failure["destination"].get("pod", ""),
                    "service_account": failure["destination"].get("service_account", ""),
                    "expected_spiffe_id": failure["destination"].get("expected_spiffe_id", ""),
                    "observed_spiffe_ids": failure["destination"].get("observed_spiffe_ids", []),
                    "serials": failure["destination"].get("serials", []),
                    "issuers": failure["destination"].get("issuers", []),
                    "proxy_log_spiffe_ids": failure["destination"].get("proxy_log_spiffe_ids", []),
                    "cert_errors": failure["destination"].get("cert_errors", []),
                    "log_error": failure["destination"].get("log_error", ""),
                }, indent=2),
                "destination cert dump:",
                failure["destination"].get("cert_dump", "").rstrip(),
                "destination proxy log:",
                failure["destination"].get("proxy_log", "").rstrip(),
                "",
                f"message: {failure['message']}",
                "",
            ]
        )
    failure_path.parent.mkdir(parents=True, exist_ok=True)
    failure_path.write_text("\n".join(lines).rstrip() + "\n")
    print(f"[FAIL] wrote artifacts/envoy_identity_validation.json ({len(connections)} workloads, {len(failures)} failures)")
    sys.exit(1)

print(f"[PASS] wrote artifacts/envoy_identity_validation.json ({len(connections)} workloads, 0 failures)")
sys.exit(0)
PY
