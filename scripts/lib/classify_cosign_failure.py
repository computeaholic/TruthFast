#!/usr/bin/env python3
"""Classify a failed cosign verification without weakening fail-closed behavior."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


FAILURE_CLASSES = {
    "SIGNATURE_ABSENT",
    "SIGNATURE_INVALID",
    "SIGNATURE_KEY_MISMATCH",
    "TRANSPARENCY_LOG_FAILURE",
    "REGISTRY_AUTH_FAILURE",
    "REGISTRY_TLS_FAILURE",
    "REGISTRY_TRANSPORT_FAILURE",
    "COSIGN_TIMEOUT",
    "COSIGN_INTERNAL_FAILURE",
}


def classify_cosign_failure(return_code: int, output: str) -> str:
    """Return the narrowest supported class supported by observed cosign output."""
    lowered = output.lower()
    if return_code in {124, 137} or any(
        marker in lowered for marker in ("timed out", "timeout", "deadline exceeded")
    ):
        return "COSIGN_TIMEOUT"
    if any(marker in lowered for marker in ("unauthorized", "authentication required", "denied", "forbidden")):
        return "REGISTRY_AUTH_FAILURE"
    if any(marker in lowered for marker in ("x509", "certificate signed", "tls", "ssl certificate")):
        return "REGISTRY_TLS_FAILURE"
    if any(
        marker in lowered
        for marker in (
            "connection refused",
            "connection reset",
            "no such host",
            "dial tcp",
            "i/o timeout",
            "unexpected eof",
            "transport endpoint",
        )
    ):
        return "REGISTRY_TRANSPORT_FAILURE"
    if any(marker in lowered for marker in ("rekor", "transparency log", "tlog", "inclusion proof")):
        return "TRANSPARENCY_LOG_FAILURE"
    if any(marker in lowered for marker in ("no signatures", "signature not found", "no matching signatures")):
        return "SIGNATURE_ABSENT"
    if any(marker in lowered for marker in ("key does not match", "public key mismatch", "wrong key")):
        return "SIGNATURE_KEY_MISMATCH"
    if any(marker in lowered for marker in ("invalid signature", "verification failed", "signature verification")):
        return "SIGNATURE_INVALID"
    return "COSIGN_INTERNAL_FAILURE"


def redact_diagnostic(output: str) -> str:
    """Remove credential-shaped values before a diagnostic is retained."""
    redacted = re.sub(
        r"(?i)(--registry-password\s+|password\s*[:=]\s*|passwd\s*[:=]\s*|token\s*[:=]\s*)\S+",
        r"\1[REDACTED]",
        output,
    )
    return re.sub(r"(?i)(https?://[^:/\s]+:)[^@\s]+(@)", r"\1[REDACTED]\2", redacted)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify = subparsers.add_parser("classify")
    classify.add_argument("--return-code", type=int, required=True)
    classify.add_argument("--input", type=Path, required=True)

    redact = subparsers.add_parser("redact")
    redact.add_argument("--input", type=Path, required=True)
    redact.add_argument("--output", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "classify":
        print(classify_cosign_failure(args.return_code, args.input.read_text(encoding="utf-8", errors="replace")))
        return 0

    args.output.write_text(
        redact_diagnostic(args.input.read_text(encoding="utf-8", errors="replace")), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
