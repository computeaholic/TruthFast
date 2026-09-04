from __future__ import annotations

import hashlib
import re
import ssl
import subprocess
import tempfile
from pathlib import Path


CERT_RE = re.compile(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----")


class IdentityRootError(RuntimeError):
    pass


def extract_unique_pems(text: str) -> list[str]:
    unique: dict[str, str] = {}
    for match in CERT_RE.findall(text or ""):
        pem = match.strip() + "\n"
        try:
            der = ssl.PEM_cert_to_DER_cert(pem)
        except ValueError as exc:
            raise IdentityRootError(f"invalid certificate in root material: {exc}") from exc
        unique.setdefault(hashlib.sha256(der).hexdigest(), pem)
    return list(unique.values())


def fingerprint(pem: str) -> str:
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def _verifies(cert_pem: str, root_pem: str, openssl_bin: str) -> bool:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        cert_path = temp / "cert.pem"
        root_path = temp / "root.pem"
        cert_path.write_text(cert_pem)
        root_path.write_text(root_pem)
        proc = subprocess.run(
            [openssl_bin, "verify", "-CAfile", str(root_path), str(cert_path)],
            text=True,
            capture_output=True,
            check=False,
        )
        return proc.returncode == 0


def select_authorized_issuance_root(
    live_bundle_pem: str,
    canonical_ca_pem: str,
    issuance_ca_pem: str,
    *,
    openssl_bin: str = "openssl",
) -> tuple[str, dict[str, object]]:
    live_roots = extract_unique_pems(live_bundle_pem)
    canonical_roots = extract_unique_pems(canonical_ca_pem)
    issuance_certs = extract_unique_pems(issuance_ca_pem)
    if not live_roots:
        raise IdentityRootError("live SPIRE bundle contains no certificates")
    if not canonical_roots:
        raise IdentityRootError("canonical SPIRE CA material contains no certificates")
    if len(issuance_certs) != 1:
        raise IdentityRootError(f"issuance CA material must contain one certificate, found {len(issuance_certs)}")

    live_by_fp = {fingerprint(pem): pem for pem in live_roots}
    canonical_fps = {fingerprint(pem) for pem in canonical_roots}
    authorized_fps = set(live_by_fp).intersection(canonical_fps)
    if not authorized_fps:
        raise IdentityRootError("live SPIRE and canonical CA material have no common authorized root")

    issuance_cert = issuance_certs[0]
    anchors = [live_by_fp[fp] for fp in sorted(authorized_fps) if _verifies(issuance_cert, live_by_fp[fp], openssl_bin)]
    if len(anchors) != 1:
        raise IdentityRootError(
            f"issuance CA chain terminates at {len(anchors)} authorized roots; "
            "expected exactly one"
        )
    anchor = anchors[0]
    return anchor, {
        "live_root_fingerprints": sorted(live_by_fp),
        "canonical_root_fingerprints": sorted(canonical_fps),
        "authorized_root_fingerprints": sorted(authorized_fps),
        "issuance_root_fingerprint": fingerprint(anchor),
    }
