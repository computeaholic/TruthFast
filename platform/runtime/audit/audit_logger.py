#!/usr/bin/env python3
"""ThreadForge structured audit logging.

Writes every event to stdout and artifacts/audit/audit.log.
If Loki endpoint is configured, writes there too.
Fail-closed: caller must treat any exception as operation failure.

Hash chain: every entry written to the audit file includes a ``prev_hash``
field that chains to the SHA-256 digest of the previous entry (computed over
all fields except ``prev_hash`` itself, using compact/sorted JSON).  The
genesis entry uses ``prev_hash = "0" * 64``.  The verifier in
``scripts/verify/verify_audit_logging.sh`` enforces this chain as mandatory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_SIGNING_KEY_REGISTRY = REPO_ROOT / "artifacts/audit/signing_key_registry.json"
DEFAULT_SIGNING_KEY_REGISTRY_SIG = REPO_ROOT / "artifacts/audit/signing_key_registry.sig"
DEFAULT_AUDIT_LOG_PATH = REPO_ROOT / "artifacts/audit/audit.log"
AUDIT_DIR_MODE = 0o750
AUDIT_FILE_MODE = 0o640


REQUIRED_FIELDS: tuple[str, ...] = (
    "timestamp",
    "actor_spiffe_id",
    "actor_role",
    "namespace",
    "action",
    "resource",
    "result",
    "reason",
)

ALLOWED_RESULTS: frozenset[str] = frozenset({"ALLOW", "DENY", "ERROR"})


class AuditLoggingError(RuntimeError):
    """Raised when required audit logging fails."""


@dataclass(frozen=True)
class AuditEvent:
    timestamp: str
    actor_spiffe_id: str
    actor_role: str
    namespace: str
    action: str
    resource: str
    result: str
    reason: str
    breakglass: bool
    request_groups: tuple[str, ...]
    signing_key_id: str

    def as_dict(self) -> dict[str, object]:
        return {
            "timestamp": self.timestamp,
            "actor_spiffe_id": self.actor_spiffe_id,
            "actor_role": self.actor_role,
            "namespace": self.namespace,
            "action": self.action,
            "resource": self.resource,
            "result": self.result,
            "reason": self.reason,
            "breakglass": self.breakglass,
            "request_groups": list(self.request_groups),
            "signing_key_id": self.signing_key_id,
        }


def _utc_now_iso() -> str:
    return datetime.now(tz=UTC).isoformat(timespec="seconds")


def _normalize_and_validate_event(raw_event: dict[str, object]) -> AuditEvent:
    missing = [k for k in REQUIRED_FIELDS if not str(raw_event.get(k, "")).strip()]
    if missing:
        raise AuditLoggingError(f"audit event missing required fields: {', '.join(missing)}")

    result = str(raw_event["result"]).strip().upper()
    if result not in ALLOWED_RESULTS:
        raise AuditLoggingError(f"invalid audit result {result!r}; expected one of {sorted(ALLOWED_RESULTS)}")

    raw_breakglass = raw_event.get("breakglass", False)
    if isinstance(raw_breakglass, bool):
        breakglass = raw_breakglass
    elif isinstance(raw_breakglass, str):
        normalized = raw_breakglass.strip().lower()
        if normalized in {"true", "1", "yes"}:
            breakglass = True
        elif normalized in {"false", "0", "no", ""}:
            breakglass = False
        else:
            raise AuditLoggingError(f"invalid breakglass value {raw_breakglass!r}; expected true/false")
    else:
        raise AuditLoggingError(f"invalid breakglass value type {type(raw_breakglass).__name__}; expected bool")

    raw_groups = raw_event.get("request_groups", ())
    request_groups: tuple[str, ...]
    if isinstance(raw_groups, str):
        request_groups = tuple(sorted({g.strip() for g in raw_groups.split(",") if g.strip()}))
    elif isinstance(raw_groups, (list, tuple, set)):
        cleaned: list[str] = []
        for item in raw_groups:
            if not isinstance(item, str):
                raise AuditLoggingError("invalid request_groups value; all groups must be strings")
            group = item.strip()
            if group:
                cleaned.append(group)
        request_groups = tuple(sorted(set(cleaned)))
    else:
        raise AuditLoggingError("invalid request_groups value type; expected CSV string or list of strings")

    if "threadforge-breakglass" in request_groups and not breakglass:
        raise AuditLoggingError(
            "request_groups contains threadforge-breakglass but breakglass=false; refusing unaudited break-glass action"
        )

    signing_key_id = str(raw_event.get("signing_key_id", "")).strip()
    if not signing_key_id:
        raise AuditLoggingError("missing signing_key_id for audit event")

    return AuditEvent(
        timestamp=str(raw_event["timestamp"]).strip(),
        actor_spiffe_id=str(raw_event["actor_spiffe_id"]).strip(),
        actor_role=str(raw_event["actor_role"]).strip(),
        namespace=str(raw_event["namespace"]).strip(),
        action=str(raw_event["action"]).strip(),
        resource=str(raw_event["resource"]).strip(),
        result=result,
        reason=str(raw_event["reason"]).strip(),
        breakglass=breakglass,
        request_groups=request_groups,
        signing_key_id=signing_key_id,
    )


def _expand_path(path: str, *, repo_root: pathlib.Path) -> pathlib.Path:
    expanded = os.path.expandvars(os.path.expanduser(path.strip()))
    p = pathlib.Path(expanded)
    if not p.is_absolute():
        p = repo_root / p
    return p.resolve()


def _load_signing_registry(path: pathlib.Path) -> dict:
    if not path.exists():
        raise AuditLoggingError(f"signing key registry missing: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AuditLoggingError(f"invalid signing key registry JSON at {path}: {exc}") from exc
    keys = payload.get("keys")
    if not isinstance(keys, dict) or not keys:
        raise AuditLoggingError(f"signing key registry has no keys: {path}")
    active = str(payload.get("active_key_id", "")).strip()
    if not active:
        raise AuditLoggingError(f"signing key registry missing active_key_id: {path}")
    if active not in keys:
        raise AuditLoggingError(f"active_key_id {active!r} not present in registry keys")
    return payload


def _resolve_registry_path(raw_path: str, *, repo_root: pathlib.Path) -> pathlib.Path:
    expanded = os.path.expandvars(os.path.expanduser(raw_path.strip()))
    path = pathlib.Path(expanded)
    if not path.is_absolute():
        path = repo_root / path
    return path.resolve()


def _verify_cosign_blob(
    *,
    cosign_bin: str,
    key_path: pathlib.Path,
    sig_path: pathlib.Path,
    blob_path: pathlib.Path,
) -> None:
    if not pathlib.Path(cosign_bin).expanduser().exists() and not shutil.which(cosign_bin):
        raise AuditLoggingError(f"cosign binary not found: {cosign_bin}")
    proc = subprocess.run(
        [
            cosign_bin,
            "verify-blob",
            "--key",
            str(key_path),
            "--signature",
            str(sig_path),
            str(blob_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        raise AuditLoggingError(f"cosign verification failed: {stderr or 'verify-blob returned non-zero'}")


def _load_trusted_signing_registry(path: pathlib.Path) -> dict:
    registry = _load_signing_registry(path)
    keys = registry["keys"]

    genesis_key_id = str(registry.get("genesis_key_id", "")).strip()
    if not genesis_key_id or genesis_key_id not in keys:
        raise AuditLoggingError("signing key registry has invalid genesis_key_id")

    for key_id, key_info in keys.items():
        if not isinstance(key_info, dict):
            raise AuditLoggingError(f"signing key registry key entry must be object: {key_id}")
        pub_raw = str(key_info.get("public_key_path", "")).strip()
        if not pub_raw:
            raise AuditLoggingError(f"signing key registry key {key_id!r} missing public_key_path")
        pub_path = _resolve_registry_path(pub_raw, repo_root=REPO_ROOT)
        if not pub_path.exists():
            raise AuditLoggingError(f"signing key public key not found for {key_id!r}: {pub_path}")

    registry_sig_target = os.getenv("THREADFORGE_SIGNING_KEY_REGISTRY_SIG", str(DEFAULT_SIGNING_KEY_REGISTRY_SIG))
    registry_sig_path = _resolve_registry_path(registry_sig_target, repo_root=REPO_ROOT)
    if not registry_sig_path.exists():
        raise AuditLoggingError(f"signing key registry signature missing: {registry_sig_path}")

    cosign_bin = os.getenv("COSIGN_BIN", str(pathlib.Path.home() / ".local/bin/cosign"))
    genesis_pub = _resolve_registry_path(str(keys[genesis_key_id]["public_key_path"]), repo_root=REPO_ROOT)

    _verify_cosign_blob(
        cosign_bin=cosign_bin,
        key_path=genesis_pub,
        sig_path=registry_sig_path,
        blob_path=path,
    )

    rotations = registry.get("rotations", [])
    if not isinstance(rotations, list):
        raise AuditLoggingError("signing key registry rotations must be an array")

    cursor = genesis_key_id
    for idx, rotation in enumerate(rotations, start=1):
        if not isinstance(rotation, dict):
            raise AuditLoggingError(f"rotation {idx} must be object")
        from_key = str(rotation.get("from", "")).strip()
        to_key = str(rotation.get("to", "")).strip()
        sig_raw = str(rotation.get("signature_path", "")).strip()
        if not from_key or not to_key or not sig_raw:
            raise AuditLoggingError(f"rotation {idx} missing required fields from/to/signature_path")
        if from_key != cursor:
            raise AuditLoggingError(
                f"rotation chain broken at step {idx}: expected from={cursor}, got from={from_key}"
            )
        if from_key not in keys or to_key not in keys:
            raise AuditLoggingError(f"rotation {idx} references untrusted key id")

        sig_path = _resolve_registry_path(sig_raw, repo_root=REPO_ROOT)
        if not sig_path.exists():
            raise AuditLoggingError(f"rotation signature missing at step {idx}: {sig_path}")
        from_pub = _resolve_registry_path(str(keys[from_key]["public_key_path"]), repo_root=REPO_ROOT)
        to_pub = _resolve_registry_path(str(keys[to_key]["public_key_path"]), repo_root=REPO_ROOT)

        _verify_cosign_blob(
            cosign_bin=cosign_bin,
            key_path=from_pub,
            sig_path=sig_path,
            blob_path=to_pub,
        )
        cursor = to_key

    active = str(registry["active_key_id"]).strip()
    if rotations and active != cursor:
        raise AuditLoggingError(
            f"active_key_id mismatch with verified rotation chain: expected {cursor}, got {active}"
        )

    return registry


def _resolve_signing_key_id(
    *,
    signing_key_id: str | None,
    signing_registry_path: str | None,
) -> str:
    registry_target = (
        signing_registry_path
        if signing_registry_path is not None
        else os.getenv("THREADFORGE_SIGNING_KEY_REGISTRY", str(DEFAULT_SIGNING_KEY_REGISTRY))
    )
    registry_path = _expand_path(registry_target, repo_root=REPO_ROOT)
    registry = _load_trusted_signing_registry(registry_path)
    keys = registry["keys"]
    active_key_id = str(registry["active_key_id"]).strip()

    effective_key_id = (signing_key_id or "").strip()
    if not effective_key_id:
        effective_key_id = active_key_id
    if effective_key_id not in keys:
        raise AuditLoggingError(
            f"signing_key_id {effective_key_id!r} is not in trusted signing key registry {registry_path}"
        )
    if effective_key_id != active_key_id:
        raise AuditLoggingError(
            f"signing_key_id {effective_key_id!r} is not active trusted key {active_key_id!r}; refusing event"
        )
    return effective_key_id


def _write_stdout(line: str) -> None:
    try:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    except Exception as exc:  # pragma: no cover
        raise AuditLoggingError(f"failed to write audit event to stdout: {exc}") from exc


def _write_file(path: pathlib.Path, line: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(path.parent, AUDIT_DIR_MODE)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, AUDIT_FILE_MODE)
    except Exception as exc:
        raise AuditLoggingError(f"failed to write audit event to file {path}: {exc}") from exc


def _read_last_line(path: pathlib.Path) -> str:
    if not path.exists():
        return ""
    try:
        with path.open("r", encoding="utf-8") as handle:
            lines = [line.strip() for line in handle if line.strip()]
    except Exception as exc:
        raise AuditLoggingError(f"failed to read audit log {path} for persistence check: {exc}") from exc
    return lines[-1] if lines else ""


def _compute_entry_hash(entry_without_prev_hash: dict) -> str:
    """SHA-256 over the compact sorted JSON of the entry (excl. prev_hash)."""
    canonical = json.dumps(entry_without_prev_hash, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _read_last_hash(path: pathlib.Path) -> str:
    """Return the hash of the last log entry, or the genesis sentinel.

    The hash is computed identically to the verifier: SHA-256 over the compact
    sorted JSON of the entry without the ``prev_hash`` field.
    """
    genesis = "0" * 64
    if not path.exists():
        return genesis
    last_line = b""
    try:
        with path.open("rb") as fh:
            # Efficiently seek to the last non-empty line.
            fh.seek(0, 2)
            size = fh.tell()
            if size == 0:
                return genesis
            pos = size - 1
            while pos >= 0:
                fh.seek(pos)
                ch = fh.read(1)
                if ch == b"\n" and pos < size - 1:
                    last_line = fh.read().strip()
                    break
                pos -= 1
            if not last_line:
                fh.seek(0)
                last_line = fh.read().strip()
    except Exception as exc:
        raise AuditLoggingError(f"failed to read last entry from audit log {path}: {exc}") from exc
    if not last_line:
        return genesis
    try:
        obj = json.loads(last_line)
    except json.JSONDecodeError as exc:
        raise AuditLoggingError(
            f"invalid JSON in canonical audit log tail {path}; refusing to append"
        ) from exc
    if not isinstance(obj, dict):
        raise AuditLoggingError(
            f"invalid canonical audit log tail {path}; expected a JSON object"
        )
    previous_hash = obj.get("prev_hash")
    if not isinstance(previous_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", previous_hash):
        raise AuditLoggingError(
            f"invalid prev_hash in canonical audit log tail {path}; refusing to append"
        )
    without_prev = {k: v for k, v in obj.items() if k != "prev_hash"}
    return _compute_entry_hash(without_prev)


def _write_loki(loki_url: str, event: AuditEvent) -> None:
    payload = {
        "streams": [
            {
                "stream": {
                    "source": "threadforge-audit",
                    "namespace": event.namespace,
                    "actor_role": event.actor_role,
                    "result": event.result,
                },
                "values": [
                    [
                        str(int(datetime.now(tz=UTC).timestamp() * 1_000_000_000)),
                        json.dumps(event.as_dict(), sort_keys=True),
                    ]
                ],
            }
        ]
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        loki_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            code = getattr(response, "status", 0)
            if code and code >= 300:
                raise AuditLoggingError(f"Loki rejected audit event with status {code}")
    except urllib.error.URLError as exc:
        raise AuditLoggingError(f"failed to write audit event to Loki {loki_url}: {exc}") from exc


def log_audit_event(
    *,
    actor_spiffe_id: str,
    actor_role: str,
    namespace: str,
    action: str,
    resource: str,
    result: str,
    reason: str,
    breakglass: bool = False,
    request_groups: tuple[str, ...] | list[str] | str = (),
    signing_key_id: str | None = None,
    signing_registry_path: str | None = None,
    timestamp: str | None = None,
    audit_log_path: str | None = None,
    loki_url: str | None = None,
) -> dict[str, object]:
    """Emit structured audit event to required sinks.

    Required sinks:
    - stdout
    - audit file

    Optional-but-enforced sink:
    - Loki, if loki_url is provided (argument or env)
    """
    resolved_signing_key_id = _resolve_signing_key_id(
        signing_key_id=signing_key_id,
        signing_registry_path=signing_registry_path,
    )

    event = _normalize_and_validate_event(
        {
            "timestamp": timestamp or _utc_now_iso(),
            "actor_spiffe_id": actor_spiffe_id,
            "actor_role": actor_role,
            "namespace": namespace,
            "action": action,
            "resource": resource,
            "result": result,
            "reason": reason,
            "breakglass": breakglass,
            "request_groups": request_groups,
            "signing_key_id": resolved_signing_key_id,
        }
    )

    audit_log_target = (
        audit_log_path
        if audit_log_path is not None
        else os.getenv("THREADFORGE_AUDIT_LOG_PATH", str(DEFAULT_AUDIT_LOG_PATH))
    )
    loki_target = loki_url if loki_url is not None else os.getenv("THREADFORGE_AUDIT_LOKI_URL", "")
    path = _expand_path(audit_log_target, repo_root=REPO_ROOT)
    loki = loki_target.strip()

    # Build chained entry: include prev_hash before writing so the verifier
    # can enforce mandatory chain integrity.
    entry_dict = event.as_dict()
    prev_hash_val = _read_last_hash(path)
    chained = dict(entry_dict)
    chained["prev_hash"] = prev_hash_val

    line = json.dumps(chained, sort_keys=True)
    _write_stdout(line)
    _write_file(path, line)
    # Fail closed: every operation must have a persisted audit event.
    persisted = _read_last_line(path)
    if persisted != line:
        if event.breakglass:
            raise AuditLoggingError(
                "break-glass audit event was not persisted; refusing silent break-glass action"
            )
        raise AuditLoggingError("audit event was not persisted; refusing operation without audit capture")
    if loki:
        _write_loki(loki, event)

    return chained


def _cli() -> int:
    parser = argparse.ArgumentParser(description="Emit ThreadForge structured audit event")
    parser.add_argument("--actor-spiffe-id", required=True)
    parser.add_argument("--actor-role", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--action", required=True)
    parser.add_argument("--resource", required=True)
    parser.add_argument("--result", required=True, choices=sorted(ALLOWED_RESULTS))
    parser.add_argument("--reason", required=True)
    parser.add_argument("--breakglass", default="false")
    parser.add_argument("--request-groups", default="")
    parser.add_argument("--signing-key-id", default="")
    parser.add_argument("--signing-registry-path", default="")
    parser.add_argument("--timestamp", default="")
    parser.add_argument("--audit-log-path", default="")
    parser.add_argument("--loki-url", default="")
    args = parser.parse_args()

    try:
        log_audit_event(
            actor_spiffe_id=args.actor_spiffe_id,
            actor_role=args.actor_role,
            namespace=args.namespace,
            action=args.action,
            resource=args.resource,
            result=args.result,
            reason=args.reason,
            breakglass=args.breakglass,
            request_groups=args.request_groups,
            signing_key_id=args.signing_key_id or None,
            signing_registry_path=args.signing_registry_path or None,
            timestamp=args.timestamp or None,
            audit_log_path=args.audit_log_path or None,
            loki_url=args.loki_url or None,
        )
    except AuditLoggingError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
