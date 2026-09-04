#!/usr/bin/env python3
"""Bootstrap preflight for deterministic registry/auth readiness.

This gate runs before cluster mutation. It validates the repository clone,
the host trust anchor, and registry reachability for upstream-sourced runtime
images so bootstrap never silently depends on local-only state.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
INVENTORY_PATH = REPO_ROOT / "platform" / "config" / "canonical_image_inventory.json"
CHECK_PREREQS = REPO_ROOT / "scripts" / "lib" / "check_prereqs.sh"
HOST_TRUST_VERIFY = REPO_ROOT / "scripts" / "infra" / "host_trust_prime.sh"
ARTIFACT_PATH = REPO_ROOT / "artifacts" / "bootstrap" / "bootstrap_preflight.json"
INTERNAL_REGISTRY_PREFIX = "registry.threadforge.local:30500/"
ALLOWED_SOURCE_TYPES = {
    "upstream",
    "local_build",
    "local_archive",
    "existing_local_image",
}


class BootstrapPreflightError(RuntimeError):
    """Raised when bootstrap preflight detects a contract violation."""

    def __init__(self, code: str, message: str, action: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.action = action


def load_inventory(path: Path = INVENTORY_PATH) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        for key in ("images", "entries", "inventory"):
            value = raw.get(key)
            if isinstance(value, list):
                return value
    raise BootstrapPreflightError(
        "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
        f"canonical image inventory has unexpected shape: {path}",
        "repair canonical inventory serialization",
    )


def is_digest_pinned(reference: str) -> bool:
    return bool(reference) and "@sha256:" in reference and not reference.endswith("@sha256:")


def registry_host(reference: str) -> str:
    if "/" not in reference:
        return reference
    return reference.split("/", 1)[0]


def is_internal_registry_ref(reference: str) -> bool:
    return reference.startswith(INTERNAL_REGISTRY_PREFIX)


def validate_inventory_entry(entry: dict) -> None:
    required = (
        "internal_reference",
        "expected_digest",
        "source_type",
        "source_reference",
        "producer",
        "local_artifact",
        "local_image_reference",
    )
    missing = [field for field in required if field not in entry]
    if missing:
        raise BootstrapPreflightError(
            "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
            f"canonical image inventory entry is missing required fields: {', '.join(missing)}",
            "repair canonical inventory generator",
        )

    source_type = str(entry["source_type"])
    if source_type not in ALLOWED_SOURCE_TYPES:
        raise BootstrapPreflightError(
            "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
            f"invalid source_type={source_type!r} in canonical inventory",
            "repair canonical inventory classification",
        )

    internal_reference = str(entry["internal_reference"])
    expected_digest = str(entry["expected_digest"])
    if not is_internal_registry_ref(internal_reference) or not is_digest_pinned(internal_reference):
        raise BootstrapPreflightError(
            "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
            f"internal_reference must be digest-pinned and registry-qualified: {internal_reference}",
            "repair canonical inventory pinning",
        )
    if internal_reference.split("@", 1)[1] != expected_digest:
        raise BootstrapPreflightError(
            "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
            f"internal_reference digest disagrees with expected_digest for {internal_reference}",
            "repair canonical inventory digest lock",
        )

    source_reference = str(entry["source_reference"])
    if source_type == "upstream":
        if is_internal_registry_ref(source_reference):
            raise BootstrapPreflightError(
                "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
                f"upstream image must not use internal registry reference: {source_reference}",
                "repair canonical inventory source classification",
            )
        if not is_digest_pinned(source_reference):
            raise BootstrapPreflightError(
                "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
                f"upstream image must be digest-pinned: {source_reference}",
                "repair canonical inventory upstream pinning",
            )
    else:
        if not source_reference:
            raise BootstrapPreflightError(
                "BOOTSTRAP_PREFLIGHT_INVALID_INVENTORY",
                f"non-upstream image is missing source_reference for {internal_reference}",
                "repair canonical inventory source metadata",
            )


def registry_probe_plan(entries: Iterable[dict]) -> OrderedDict[str, str]:
    probes: OrderedDict[str, str] = OrderedDict()
    for entry in entries:
        source_type = str(entry["source_type"])
        if source_type != "upstream":
            continue
        reference = str(entry["source_reference"])
        host = registry_host(reference)
        probes.setdefault(host, reference)
    return probes


def classify_registry_probe_failure(output: str) -> tuple[str, str]:
    lowered = output.lower()
    if any(token in lowered for token in ("unauthorized", "authentication required", "denied")):
        return "REGISTRY_AUTH_VALIDATION", "registry authentication required"
    if any(token in lowered for token in ("x509", "certificate", "tls", "ssl")):
        return "REGISTRY_TLS_FAILURE", "registry TLS verification failed"
    if any(token in lowered for token in ("manifest unknown", "not found", "name unknown")):
        return "MISSING_IMAGE", "registry image not found"
    return "REGISTRY_PROBE_FAILURE", "registry probe failed"


def run_command(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=False, capture_output=True, text=True)


def verify_repo_clone() -> None:
    result = run_command(["git", "-C", str(REPO_ROOT), "rev-parse", "--is-inside-work-tree"])
    if result.returncode != 0 or result.stdout.strip() != "true":
        raise BootstrapPreflightError(
            "HIDDEN_BOOTSTRAP_ASSUMPTIONS",
            "repository is not a valid git worktree",
            "clone the repository before bootstrapping",
        )


def verify_required_prereqs() -> None:
    result = subprocess.run(
        ["bash", str(CHECK_PREREQS)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise BootstrapPreflightError(
            "BOOTSTRAP_PREFLIGHT_PREREQ_FAILURE",
            result.stdout.strip() or result.stderr.strip() or "bootstrap prereq check failed",
            "install missing host tools and rerun bootstrap",
        )


def verify_host_trust() -> None:
    result = subprocess.run(
        ["bash", str(HOST_TRUST_VERIFY), "--mode", "verify"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise BootstrapPreflightError(
            "HOST_TRUST_REQUIRED",
            result.stdout.strip() or result.stderr.strip() or "host trust verification failed",
            "prime host trust before bootstrap",
        )


def probe_registry(reference: str) -> dict:
    result = subprocess.run(
        [
            "skopeo",
            "inspect",
            "--tls-verify=true",
            "--format",
            "{{.Digest}}",
            f"docker://{reference}",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    output = (result.stdout + "\n" + result.stderr).strip()
    if result.returncode == 0:
        return {
            "host": registry_host(reference),
            "reference": reference,
            "status": "PASS",
        }

    code, detail = classify_registry_probe_failure(output)
    raise BootstrapPreflightError(
        code,
        f"{detail} for {reference}: {output or 'no output'}",
        "repair registry publication or upstream registry access",
    )


def run_preflight() -> dict:
    verify_required_prereqs()
    verify_repo_clone()
    verify_host_trust()

    inventory = load_inventory()
    for entry in inventory:
        validate_inventory_entry(entry)

    probes = registry_probe_plan(inventory)
    checked = [probe_registry(reference) for reference in probes.values()]
    return {
        "bootstrapped": True,
        "bootstrap_preflight": "PASS",
        "registry_auth_validation": "PASS",
        "hidden_bootstrap_assumptions": 0,
        "ready_for_bootstrap": True,
        "inventory_entries": len(inventory),
        "upstream_registry_probes": checked,
    }


def write_artifact(payload: dict, artifact_path: Path) -> None:
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_text(
        json.dumps(
            {
                **payload,
                "timestamp_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--artifact",
        default=str(ARTIFACT_PATH),
        help="Write the bootstrap preflight artifact here (default: canonical bootstrap artifact path)",
    )
    args = parser.parse_args(argv)
    artifact_path = Path(args.artifact)

    try:
        payload = run_preflight()
    except BootstrapPreflightError as exc:
        write_artifact(
            {
                "status": "FAIL",
                "classification": exc.code,
                "reason": exc.message,
                "required_action": exc.action,
            },
            artifact_path,
        )
        print(f"[FAIL] {exc.code}: {exc.message}")
        print(f"[INFO] required_action={exc.action}")
        print(f"[INFO] artifact={artifact_path}")
        return 2

    write_artifact({"status": "PASS", **payload}, artifact_path)
    print("[PASS] BOOTSTRAP_PREFLIGHT=PASS")
    print("[PASS] REGISTRY_AUTH_VALIDATION=PASS")
    print("[PASS] HIDDEN_BOOTSTRAP_ASSUMPTIONS=0")
    print("[PASS] READY_FOR_BOOTSTRAP=YES")
    print(f"[INFO] artifact={artifact_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
