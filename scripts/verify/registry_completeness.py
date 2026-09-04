#!/usr/bin/env python3

import argparse
import concurrent.futures
import dataclasses
import json
import os
import pathlib
import re
import subprocess
import threading
import time
from typing import Iterable


def sign_verification_budget_seconds(
    *, skopeo_timeout: int, cosign_timeout: int, cosign_retries: int, retry_interval: int
) -> int:
    """Bound the complete sign_images verify helper, including its retries."""
    return (
        skopeo_timeout
        + (cosign_timeout * cosign_retries)
        + (retry_interval * max(cosign_retries - 1, 0))
        + 1
    )


DIGEST_REF_RE = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")


@dataclasses.dataclass(frozen=True)
class CanonicalRef:
    raw_ref: str
    canonical_ref: str
    digest: str
    source: str


@dataclasses.dataclass(frozen=True)
class DigestGroup:
    digest: str
    representative_ref: str
    canonical_refs: tuple[str, ...]
    raw_refs: tuple[str, ...]
    sources: tuple[str, ...]


def read_refs(path: pathlib.Path) -> list[str]:
    refs: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.split("#", 1)[0].strip()
        if stripped:
            refs.append(stripped)
    return refs


def load_pin_map(path: pathlib.Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    pin_map: dict[str, str] = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, str):
            pin_map[key.strip()] = value.strip()
    return pin_map


def canonicalize_ref(raw_ref: str, pin_map: dict[str, str], allowed_prefix: str) -> tuple[str, str]:
    ref = pin_map.get(raw_ref.strip(), raw_ref.strip())
    ref_prefix = ref.rsplit("@", 1)[0]
    last_segment = ref_prefix.rsplit("/", 1)[-1]
    if ":" in last_segment:
        raise ValueError(f"image uses mutable tag before digest: {raw_ref}")
    match = DIGEST_REF_RE.match(ref)
    if not match:
        raise ValueError(f"image must be digest pinned: {raw_ref}")

    name = match.group("name")
    digest = match.group("digest").lower()
    canonical_ref = f"{name}@{digest}"
    if not canonical_ref.startswith(allowed_prefix):
        raise ValueError(f"image not in allowed registry: {raw_ref}")
    return canonical_ref, digest


def build_canonical_refs(
    refs_by_source: dict[str, list[str]],
    *,
    pin_map: dict[str, str],
    allowed_prefix: str,
) -> tuple[list[CanonicalRef], list[str]]:
    canonical_refs: list[CanonicalRef] = []
    errors: list[str] = []
    for source, refs in refs_by_source.items():
        for raw_ref in refs:
            try:
                canonical_ref, digest = canonicalize_ref(raw_ref, pin_map, allowed_prefix)
            except ValueError as exc:
                errors.append(f"{source}: {exc}")
                continue
            canonical_refs.append(
                CanonicalRef(
                    raw_ref=raw_ref,
                    canonical_ref=canonical_ref,
                    digest=digest,
                    source=source,
                )
            )
    return canonical_refs, errors


def build_digest_groups(canonical_refs: Iterable[CanonicalRef]) -> list[DigestGroup]:
    grouped: dict[str, list[CanonicalRef]] = {}
    for canonical_ref in canonical_refs:
        grouped.setdefault(canonical_ref.digest, []).append(canonical_ref)

    digest_groups: list[DigestGroup] = []
    for digest, refs in sorted(grouped.items(), key=lambda item: item[0]):
        refs_sorted = sorted(refs, key=lambda item: item.canonical_ref)
        canonical_refs_unique = tuple(sorted({ref.canonical_ref for ref in refs_sorted}))
        raw_refs_unique = tuple(dict.fromkeys(ref.raw_ref for ref in refs_sorted))
        sources_unique = tuple(dict.fromkeys(ref.source for ref in refs_sorted))
        digest_groups.append(
            DigestGroup(
                digest=digest,
                representative_ref=canonical_refs_unique[0],
                canonical_refs=canonical_refs_unique,
                raw_refs=raw_refs_unique,
                sources=sources_unique,
            )
        )
    return digest_groups


def digest_set_postcondition(expected_digests: Iterable[str], results: Iterable[dict]) -> dict:
    expected = set(expected_digests)
    verified = {
        result.get("digest")
        for result in results
        if result.get("status") != "FAIL" and result.get("digest")
    }
    failed = {
        result.get("digest")
        for result in results
        if result.get("status") == "FAIL" and result.get("digest")
    }
    return {
        "expected": sorted(expected),
        "verified": sorted(verified),
        "failed": sorted(failed),
        "missing": sorted(expected - verified),
        "excess": sorted(verified - expected),
        "exact_equality": expected == verified and not failed,
    }


def write_json(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp_path, path)


def run_command(
    command: list[str], *, env: dict[str, str] | None = None, timeout_seconds: int | None = None
) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            timeout=timeout_seconds,
            check=False,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return 124, output


def classify_skopeo_error(output: str) -> str:
    lowered = output.lower()
    if any(token in lowered for token in ("x509", "certificate", "tls", "ssl")):
        return "REGISTRY_TLS_FAILURE"
    if any(token in lowered for token in ("unauthorized", "authentication required", "denied")):
        return "REGISTRY_AUTH_FAILURE"
    if any(token in lowered for token in ("manifest unknown", "not found", "name unknown")):
        return "REGISTRY_MANIFEST_NOT_FOUND"
    return "DIGEST_MISMATCH"


def verify_digest_group(
    digest_group: DigestGroup,
    *,
    registry_host: str,
    registry_port: str,
    registry_user: str,
    registry_password: str,
    registry_ca_cert: pathlib.Path,
    sign_script: pathlib.Path,
    probe_namespace: str,
    probe_pod: str,
    probe_container: str,
    probe_mount_path: str,
    skopeo_inspect_timeout_seconds: int,
    skopeo_inspect_retries: int,
    skopeo_inspect_retry_interval_seconds: int,
    probe_request_timeout_seconds: int,
    probe_request_retries: int,
    probe_request_retry_interval_seconds: int,
    sign_verify_timeout_seconds: int,
) -> dict:
    digest = digest_group.digest
    ref = digest_group.representative_ref
    registry_image = f"docker://{ref}"
    registry_cert_dir_str = str(registry_ca_cert.parent)
    sign_env = os.environ.copy()
    sign_env.pop("REGISTRY_CERT_DIR", None)
    sign_env["REGISTRY_CA_CERT_PATH"] = str(registry_ca_cert)
    cosign_timeout = int(sign_env.get("COSIGN_VERIFY_TIMEOUT_SECONDS", str(sign_verify_timeout_seconds)))
    cosign_retries = int(sign_env.get("COSIGN_VERIFY_RETRIES", "5"))
    cosign_retry_interval = int(sign_env.get("COSIGN_VERIFY_RETRY_INTERVAL_SECONDS", "2"))
    sign_helper_timeout = sign_verification_budget_seconds(
        skopeo_timeout=skopeo_inspect_timeout_seconds,
        cosign_timeout=cosign_timeout,
        cosign_retries=cosign_retries,
        retry_interval=cosign_retry_interval,
    )

    resolve_attempts = 0
    resolve_output = ""
    resolve_rc = 0

    for attempt in range(1, skopeo_inspect_retries + 1):
        resolve_attempts = attempt
        resolve_rc, resolve_output = run_command(
            [
                "timeout",
                f"{skopeo_inspect_timeout_seconds}s",
                "skopeo",
                "inspect",
                "--creds",
                f"{registry_user}:{registry_password}",
                "--cert-dir",
                registry_cert_dir_str,
                "--tls-verify=true",
                "--override-os",
                sign_env.get("SIGN_IMAGES_OS", "linux"),
                "--override-arch",
                sign_env.get("SIGN_IMAGES_ARCH", "arm64"),
                "--format",
                "{{.Digest}}",
                registry_image,
            ]
        )
        resolved_digest = resolve_output.strip()
        if resolve_rc == 0 and resolved_digest == digest:
            break
        if attempt < skopeo_inspect_retries:
            time.sleep(skopeo_inspect_retry_interval_seconds)
    else:
        resolved_digest = resolve_output.strip()
        raise RuntimeError(
            f"REGISTRY_DIGEST_MISMATCH: {ref} (expected {digest}, got {resolved_digest or 'UNSET'})"
        )

    sign_rc, sign_output = run_command(
        [
            "env",
            "-u",
            "REGISTRY_CERT_DIR",
            str(sign_script),
            "--mode",
            "verify",
            "--image",
            ref,
        ],
        env=sign_env,
        timeout_seconds=sign_helper_timeout,
    )
    if sign_rc != 0:
        raise RuntimeError(f"SIGNATURE_VERIFICATION_FAILED: {ref}\n{sign_output.strip()}")

    repo_path = ref.split("/", 1)[1].split("@", 1)[0]
    probe_attempts = 0
    probe_output = ""
    probe_rc = 0
    for attempt in range(1, probe_request_retries + 1):
        probe_attempts = attempt
        probe_cmd = [
            "timeout",
            f"{probe_request_timeout_seconds}s",
            "kubectl",
            "exec",
            "-n",
            probe_namespace,
            probe_pod,
            "-c",
            probe_container,
            "--",
            "sh",
            "-c",
            (
                "curl -sS --cacert "
                f"'{probe_mount_path}' "
                f"-u '{registry_user}:{registry_password}' "
                "-H 'Accept: application/vnd.oci.image.manifest.v1+json,"
                "application/vnd.docker.distribution.manifest.v2+json,"
                "application/vnd.oci.image.index.v1+json,"
                "application/vnd.docker.distribution.manifest.list.v2+json' "
                "-o /dev/null -w '%{http_code}' "
                f"'https://{registry_host}:{registry_port}/v2/{repo_path}/manifests/{digest}'"
            ),
        ]
        probe_rc, probe_output = run_command(probe_cmd)
        http_code = "".join(ch for ch in probe_output if ch.isdigit())[-3:]
        if http_code == "200":
            break
        if attempt < probe_request_retries:
            time.sleep(probe_request_retry_interval_seconds)
    else:
        http_code = "".join(ch for ch in probe_output if ch.isdigit())[-3:] or "000"
        kind = classify_skopeo_error(probe_output)
        raise RuntimeError(f"{kind}: {ref} (probe={http_code})\n{probe_output.strip()}")

    http_code = "".join(ch for ch in probe_output if ch.isdigit())[-3:]

    return {
        "digest": digest,
        "representative_ref": ref,
        "canonical_refs": list(digest_group.canonical_refs),
        "raw_refs": list(digest_group.raw_refs),
        "sources": list(digest_group.sources),
        "resolve_attempts": resolve_attempts,
        "resolve_rc": resolve_rc,
        "sign_rc": sign_rc,
        "probe_attempts": probe_attempts,
        "probe_http_code": http_code,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify registry completeness with canonical digest deduplication")
    parser.add_argument("--expected", type=pathlib.Path, required=True)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--allowed", type=pathlib.Path, required=True)
    parser.add_argument("--pin-map", type=pathlib.Path, required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--probe-namespace", required=True)
    parser.add_argument("--probe-pod", required=True)
    parser.add_argument("--probe-container", required=True)
    parser.add_argument("--probe-mount-path", required=True)
    parser.add_argument("--registry-host", required=True)
    parser.add_argument("--registry-port", required=True)
    parser.add_argument("--registry-user", required=True)
    parser.add_argument("--registry-password", required=True)
    parser.add_argument("--registry-ca-cert", type=pathlib.Path, required=True)
    parser.add_argument("--sign-script", type=pathlib.Path, required=True)
    parser.add_argument("--skopeo-inspect-timeout-seconds", type=int, default=25)
    parser.add_argument("--skopeo-inspect-retries", type=int, default=3)
    parser.add_argument("--skopeo-inspect-retry-interval-seconds", type=int, default=2)
    parser.add_argument("--probe-request-timeout-seconds", type=int, default=20)
    parser.add_argument("--probe-request-retries", type=int, default=3)
    parser.add_argument("--probe-request-retry-interval-seconds", type=int, default=2)
    parser.add_argument("--sign-verify-timeout-seconds", type=int, default=180)
    parser.add_argument("--max-concurrency", type=int, default=4)
    args = parser.parse_args()

    started = time.time()
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    inventory_path = output_dir / "registry_completeness_inventory.json"
    summary_path = output_dir / "registry_completeness_summary.txt"

    allowed_prefix = "registry.threadforge.local:30500/"
    pin_map = load_pin_map(args.pin_map)
    refs_by_source = {
        "expected": read_refs(args.expected),
        "runtime": read_refs(args.runtime),
        "allowed": read_refs(args.allowed),
    }

    canonical_refs, canonical_errors = build_canonical_refs(
        refs_by_source, pin_map=pin_map, allowed_prefix=allowed_prefix
    )
    if canonical_errors:
        raise RuntimeError("REGISTRY_COMPLETENESS_INPUT_INVALID:\n" + "\n".join(canonical_errors))

    unique_canonical_refs = sorted({ref.canonical_ref for ref in canonical_refs})
    digest_groups = build_digest_groups(canonical_refs)
    unique_digests = [group.digest for group in digest_groups]

    plan = {
        "input_image_refs": sum(len(refs) for refs in refs_by_source.values()),
        "unique_canonical_refs": len(unique_canonical_refs),
        "unique_digests": len(unique_digests),
        "skopeo_calls_before": len(unique_canonical_refs),
        "skopeo_calls_after": len(unique_digests),
        "signature_verifications_before": len(unique_canonical_refs),
        "signature_verifications_after": len(unique_digests),
        "serial_network_operations_before": len(unique_canonical_refs) * 3,
        "serial_network_operations_after": len(unique_digests) * 3,
        "max_concurrency_after": max(1, min(args.max_concurrency, len(digest_groups) or 1)),
        "retry_budget_per_unique_digest": {
            "skopeo_inspect_retries": args.skopeo_inspect_retries,
            "probe_request_retries": args.probe_request_retries,
            "sign_verify_timeout_seconds": args.sign_verify_timeout_seconds,
        },
        "started_epoch": started,
    }

    snapshot = {
        "plan": plan,
        "sources": refs_by_source,
        "canonical_refs": [
            {
                "raw_ref": ref.raw_ref,
                "canonical_ref": ref.canonical_ref,
                "digest": ref.digest,
                "source": ref.source,
            }
            for ref in canonical_refs
        ],
        "digest_groups": [
            dataclasses.asdict(group)
            for group in digest_groups
        ],
        "results": [],
        "status": "RUNNING",
    }
    write_json(inventory_path, snapshot)

    print(
        "[registry-completeness] START "
        f"INPUT_IMAGE_REFS={plan['input_image_refs']} "
        f"UNIQUE_CANONICAL_REFS={plan['unique_canonical_refs']} "
        f"UNIQUE_DIGESTS={plan['unique_digests']} "
        f"SKOPEO_CALLS_BEFORE={plan['skopeo_calls_before']} "
        f"SKOPEO_CALLS_AFTER={plan['skopeo_calls_after']} "
        f"SIGNATURE_VERIFICATIONS_BEFORE={plan['signature_verifications_before']} "
        f"SIGNATURE_VERIFICATIONS_AFTER={plan['signature_verifications_after']} "
        f"SERIAL_NETWORK_OPERATIONS_BEFORE={plan['serial_network_operations_before']} "
        f"MAX_CONCURRENCY_AFTER={plan['max_concurrency_after']} "
        f"RETRY_BUDGET_PER_UNIQUE_DIGEST=skopeo_inspect:{args.skopeo_inspect_retries},"
        f"probe:{args.probe_request_retries},sign_timeout:{args.sign_verify_timeout_seconds}",
        flush=True,
    )
    print(f"[registry-completeness] inventory={inventory_path}", flush=True)

    results: list[dict] = []
    results_lock = threading.Lock()
    completed = 0
    stop_event = threading.Event()

    def update_snapshot(status: str, failure: str | None = None) -> None:
        snapshot["results"] = results
        snapshot["status"] = status
        snapshot["completed"] = completed
        snapshot["failure"] = failure
        snapshot["digest_set_postcondition"] = digest_set_postcondition(unique_digests, results)
        snapshot["plan"]["finished_epoch"] = time.time()
        snapshot["plan"]["elapsed_seconds"] = round(snapshot["plan"]["finished_epoch"] - started, 3)
        write_json(inventory_path, snapshot)

    def progress_line() -> str:
        elapsed = round(time.time() - started, 3)
        return (
            "[registry-completeness] PROGRESS "
            f"completed={completed}/{len(digest_groups)} "
            f"in_flight={max(0, len(digest_groups) - completed)} "
            f"elapsed_seconds={elapsed} "
            f"cache_entries={len(results)}"
        )

    def reporter() -> None:
        while not stop_event.wait(30):
            print(progress_line(), flush=True)

    reporter_thread = threading.Thread(target=reporter, name="registry-completeness-progress", daemon=True)
    reporter_thread.start()

    failures: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=plan["max_concurrency_after"]) as executor:
        future_map = {
            executor.submit(
                verify_digest_group,
                group,
                registry_host=args.registry_host,
                registry_port=args.registry_port,
                registry_user=args.registry_user,
                registry_password=args.registry_password,
                registry_ca_cert=args.registry_ca_cert,
                sign_script=args.sign_script,
                probe_namespace=args.probe_namespace,
                probe_pod=args.probe_pod,
                probe_container=args.probe_container,
                probe_mount_path=args.probe_mount_path,
                skopeo_inspect_timeout_seconds=args.skopeo_inspect_timeout_seconds,
                skopeo_inspect_retries=args.skopeo_inspect_retries,
                skopeo_inspect_retry_interval_seconds=args.skopeo_inspect_retry_interval_seconds,
                probe_request_timeout_seconds=args.probe_request_timeout_seconds,
                probe_request_retries=args.probe_request_retries,
                probe_request_retry_interval_seconds=args.probe_request_retry_interval_seconds,
                sign_verify_timeout_seconds=args.sign_verify_timeout_seconds,
            ): group
            for group in digest_groups
        }

        for future in concurrent.futures.as_completed(future_map):
            group = future_map[future]
            try:
                result = future.result()
            except Exception as exc:
                result = {
                    "digest": group.digest,
                    "representative_ref": group.representative_ref,
                    "canonical_refs": list(group.canonical_refs),
                    "raw_refs": list(group.raw_refs),
                    "sources": list(group.sources),
                    "status": "FAIL",
                    "error": str(exc),
                }
                failures.append(result)
                print(
                    "[FAIL] REGISTRY_COMPLETENESS_DIGEST_FAILED "
                    f"digest={group.digest} representative_ref={group.representative_ref} "
                    f"error={exc}",
                    flush=True,
                )
            with results_lock:
                results.append(result)
                completed_count = len(results)
            completed = completed_count
            update_snapshot("RUNNING")
            if result.get("status") != "FAIL":
                print(
                    "[registry-completeness] VERIFIED "
                    f"digest={group.digest} "
                    f"representative_ref={group.representative_ref} "
                    f"aliases={len(group.canonical_refs)} "
                    f"completed={completed}/{len(digest_groups)}",
                    flush=True,
                )
            print(progress_line(), flush=True)

    stop_event.set()
    reporter_thread.join(timeout=5)
    finished = time.time()
    if failures:
        set_postcondition = digest_set_postcondition(unique_digests, results)
        failure_text = "; ".join(
            f"{item['digest']}={item['error']}" for item in failures
        )
        update_snapshot("FAIL", failure_text)
        print(
            f"[FAIL] REGISTRY_COMPLETENESS_FAILED: {len(failures)} digest(s) failed; "
            "all failures were collected",
            flush=True,
        )
        summary_path.write_text(
            "\n".join(
                [
                    "STATUS=FAIL",
                    f"UNIQUE_DIGESTS={len(unique_digests)}",
                    f"FAILED_DIGESTS={len(failures)}",
                    f"FAILED_VERIFICATION_DIGESTS={','.join(item['digest'] for item in failures)}",
                    f"EXPECTED_SET_COUNT={len(set_postcondition['expected'])}",
                    f"VERIFIED_SET_COUNT={len(set_postcondition['verified'])}",
                    f"MISSING_SET={','.join(set_postcondition['missing'])}",
                    f"EXCESS_SET={','.join(set_postcondition['excess'])}",
                    f"EXACT_SET_EQUALITY={str(set_postcondition['exact_equality']).upper()}",
                    f"INVENTORY_PATH={inventory_path}",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        return 11
    update_snapshot("PASS")
    set_postcondition = digest_set_postcondition(unique_digests, results)
    if not set_postcondition["exact_equality"]:
        update_snapshot("FAIL", "registry digest set postcondition failed")
        summary_path.write_text(
            "\n".join(
                [
                    "STATUS=FAIL",
                    f"UNIQUE_DIGESTS={len(unique_digests)}",
                    f"FAILED_DIGESTS={len(set_postcondition['failed'])}",
                    f"EXPECTED_SET_COUNT={len(set_postcondition['expected'])}",
                    f"VERIFIED_SET_COUNT={len(set_postcondition['verified'])}",
                    f"MISSING_SET={','.join(set_postcondition['missing'])}",
                    f"EXCESS_SET={','.join(set_postcondition['excess'])}",
                    "EXACT_SET_EQUALITY=FALSE",
                    f"INVENTORY_PATH={inventory_path}",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        print(
            "[FAIL] REGISTRY_COMPLETENESS_SET_POSTCONDITION_FAILED "
            f"missing={','.join(set_postcondition['missing']) or 'none'} "
            f"excess={','.join(set_postcondition['excess']) or 'none'}",
            flush=True,
        )
        return 12

    elapsed_seconds = round(finished - started, 3)
    print(
        "[registry-completeness] END PASS "
        f"INPUT_IMAGE_REFS={plan['input_image_refs']} "
        f"UNIQUE_CANONICAL_REFS={plan['unique_canonical_refs']} "
        f"UNIQUE_DIGESTS={plan['unique_digests']} "
        f"SKOPEO_CALLS_BEFORE={plan['skopeo_calls_before']} "
        f"SKOPEO_CALLS_AFTER={plan['skopeo_calls_after']} "
        f"SIGNATURE_VERIFICATIONS_BEFORE={plan['signature_verifications_before']} "
        f"SIGNATURE_VERIFICATIONS_AFTER={plan['signature_verifications_after']} "
        f"SERIAL_NETWORK_OPERATIONS_BEFORE={plan['serial_network_operations_before']} "
        f"SERIAL_NETWORK_OPERATIONS_AFTER={plan['serial_network_operations_after']} "
        f"MAX_CONCURRENCY_AFTER={plan['max_concurrency_after']} "
        f"RETRY_BUDGET_PER_UNIQUE_DIGEST=skopeo_inspect:{args.skopeo_inspect_retries},"
        f"probe:{args.probe_request_retries},sign_timeout:{args.sign_verify_timeout_seconds} "
        f"BEFORE_METRIC_PROVEN=INPUT_IMAGE_REFS "
        f"BEFORE_METRIC_DERIVED=SKOPEO_CALLS_BEFORE,SIGNATURE_VERIFICATIONS_BEFORE,SERIAL_NETWORK_OPERATIONS_BEFORE "
        f"AFTER_METRIC_MEASURED=SKOPEO_CALLS_AFTER,SIGNATURE_VERIFICATIONS_AFTER,SERIAL_NETWORK_OPERATIONS_AFTER "
        f"TOTAL_REGISTRY_COMPLETENESS_DURATION_BEFORE=UNKNOWN_NOT_MEASURED "
        f"TOTAL_REGISTRY_COMPLETENESS_DURATION_AFTER={elapsed_seconds}s",
        flush=True,
    )
    print(f"[registry-completeness] inventory={inventory_path}", flush=True)
    print(f"[registry-completeness] summary={summary_path}", flush=True)
    summary_path.write_text(
        "\n".join(
            [
                "STATUS=PASS",
                f"INPUT_IMAGE_REFS={plan['input_image_refs']}",
                f"UNIQUE_CANONICAL_REFS={plan['unique_canonical_refs']}",
                f"UNIQUE_DIGESTS={plan['unique_digests']}",
                f"SKOPEO_CALLS_BEFORE={plan['skopeo_calls_before']}",
                f"SKOPEO_CALLS_AFTER={plan['skopeo_calls_after']}",
                f"SIGNATURE_VERIFICATIONS_BEFORE={plan['signature_verifications_before']}",
                f"SIGNATURE_VERIFICATIONS_AFTER={plan['signature_verifications_after']}",
                f"SERIAL_NETWORK_OPERATIONS_BEFORE={plan['serial_network_operations_before']}",
                f"SERIAL_NETWORK_OPERATIONS_AFTER={plan['serial_network_operations_after']}",
                f"MAX_CONCURRENCY_AFTER={plan['max_concurrency_after']}",
                "RETRY_BUDGET_PER_UNIQUE_DIGEST="
                f"skopeo_inspect:{args.skopeo_inspect_retries},"
                f"probe:{args.probe_request_retries},"
                f"sign_timeout:{args.sign_verify_timeout_seconds}",
                f"EXPECTED_SET_COUNT={len(set_postcondition['expected'])}",
                f"VERIFIED_SET_COUNT={len(set_postcondition['verified'])}",
                "MISSING_SET=",
                "EXCESS_SET=",
                "EXACT_SET_EQUALITY=TRUE",
                f"TOTAL_REGISTRY_COMPLETENESS_DURATION_BEFORE=0s",
                f"TOTAL_REGISTRY_COMPLETENESS_DURATION_AFTER={elapsed_seconds}s",
                f"INVENTORY_PATH={inventory_path}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
