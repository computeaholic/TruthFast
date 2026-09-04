#!/usr/bin/env python3
"""Sign Civ DecisionRecord JSON artifacts using ArtifactSigner.

Usage: CIV_SIGNING_KEY must be set (hex-encoded 32 bytes) for the step to run.
Example:
  CIV_SIGNING_KEY=<hex> python3 scripts/sign_civ_artifacts.py artifacts/civ/decisions

This script signs each JSON file in the provided directory (non-recursive) by:
 - Loading the JSON
 - Removing any existing signature/signing_key_id/algorithm/signed_content_hash fields
 - Producing canonical JSON using json.dumps(..., sort_keys=True)
 - Calling ArtifactSigner.sign_artifact(content_str)
 - Injecting signature, signing_key_id, algorithm and signed_content_hash into file
"""

import json
import logging
import sys
from pathlib import Path

from runtime.civ.provenance.artifact_signing import ArtifactSigner, SigningError

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("sign_civ_artifacts")


def sign_file(signer: ArtifactSigner, path: Path) -> None:
    j = json.loads(path.read_text())
    # Remove existing signature metadata if present
    for k in ["signature", "signing_key_id", "algorithm", "signed_content_hash"]:
        j.pop(k, None)

    # Canonical content
    content_str = json.dumps(j, sort_keys=True, separators=(",", ":"))

    meta = signer.sign_artifact(content_str)

    # Add fields back
    j["signature"] = meta["signature"]
    j["signing_key_id"] = signer.key_id
    j["algorithm"] = meta.get("algorithm", "ed25519")
    j["signed_content_hash"] = meta["signed_content_hash"]

    path.write_text(json.dumps(j, indent=2, sort_keys=False) + "\n")
    log.info("Signed %s (key_id=%s)", path, signer.key_id)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: scripts/sign_civ_artifacts.py <artifacts_dir>", file=sys.stderr)
        return 2

    artifacts_dir = Path(argv[1])
    if not artifacts_dir.is_dir():
        print(f"Artifacts dir not found: {artifacts_dir}", file=sys.stderr)
        return 2

    try:
        signer = ArtifactSigner()
    except SigningError as e:
        print(f"Signing not available: {e}", file=sys.stderr)
        return 3

    for p in sorted(artifacts_dir.glob("*.json")):
        try:
            sign_file(signer, p)
        except Exception as e:
            log.exception("Failed to sign %s: %s", p, e)
            return 4

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
