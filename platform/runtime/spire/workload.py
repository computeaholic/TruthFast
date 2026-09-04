from __future__ import annotations

import os
import socket
from hashlib import sha3_512
from typing import Tuple

from runtime.spire.grpc_client import GRPCClientError, fetch_and_validate_svid_via_grpc
from runtime.spire.svid_cli import fetch_x509svid_via_cli

# cryptography is a hard runtime dependency (declared in requirements/runtime.txt)
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.asymmetric.dsa import DSAPublicKey
from cryptography.hazmat.primitives.asymmetric.ec import ECDSA, EllipticCurvePublicKey
from cryptography.hazmat.primitives.asymmetric.ed448 import Ed448PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from cryptography.hazmat.primitives.serialization import Encoding


def is_workload_api_responsive(socket_path: str, timeout: float = 0.5) -> bool:
    """Best-effort check that the SPIRE Workload API is responsive.

    Strategy: attempt to connect to the UNIX domain socket within a short timeout.
    A successful connect indicates the agent Workload API is listening and reachable.

    Note: This is intentionally lightweight and deterministic for tests; callers
    may augment with a real SVID fetch if gRPC/proto deps are available.
    """
    if not os.path.exists(socket_path):
        return False

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.close()
        return True
    except Exception:
        return False


class SVIDValidationError(Exception):
    pass


def _compute_identity_hash_from_cert(cert_der: bytes) -> str:
    h = sha3_512()
    h.update(cert_der)
    return f"sha3-512:{h.hexdigest()}"


def fetch_and_validate_svid(socket_path: str) -> Tuple[str, str]:
    """Fetch an X.509 SVID and validate it.

    Primary (authoritative): use the gRPC Workload API client.
    CLI is allowed as a dev-only fallback but CANNOT be used to transition to
    AUTHORITATIVE state — callers that depend on authoritative identity MUST
    call the gRPC path explicitly (see fetch_and_validate_svid_via_grpc).
    """
    # Attempt gRPC first (authoritative path)
    try:
        return fetch_and_validate_svid_via_grpc(socket_path)
    except GRPCClientError as e:
        # Fall through: do not treat CLI as authoritative. Raise SVIDValidationError
        # to indicate authoritative fetch failed.
        raise SVIDValidationError(f"gRPC SVID fetch/validation failed: {e}") from e


# Development helper: non-authoritative CLI path
def fetch_and_validate_svid_cli_dev(socket_path: str) -> Tuple[str, str]:
    """Non-authoritative development helper that uses CLI to fetch SVIDs.

    This function is explicitly non-authoritative and should not be used for
    production authority decisions. It exists only to aid local testing.
    """
    raw = fetch_x509svid_via_cli(socket_path)
    if raw is None:
        raise SVIDValidationError("SPIRE CLI fetch failed or not available")

    try:
        svids = raw.get("x509_svids") or raw.get("svids") or []
        if not svids:
            raise SVIDValidationError("No x509 SVIDs returned by agent")

        first = svids[0]
        pem = first.get("svid") or first.get("cert_pem") or first.get("cert")
        spiffe_id = first.get("spiffe_id") or first.get("spiffeID") or first.get("spiffeId")
        bundle_pem = raw.get("bundle") or raw.get("x509_bundle") or None

        if pem is None or spiffe_id is None:
            raise SVIDValidationError("SVID payload missing spiffe_id or cert")

        cert = x509.load_pem_x509_certificate(pem.encode("utf-8"))
        cert_der = cert.public_bytes(Encoding.DER)
        identity_hash = _compute_identity_hash_from_cert(cert_der)

        # Basic bundle validation as in the gRPC pathway
        if bundle_pem:
            bundle_certs = []
            for part in bundle_pem.split("-----END CERTIFICATE-----"):
                part = part.strip()
                if not part:
                    continue
                part = part + "-----END CERTIFICATE-----\n"
                try:
                    c = x509.load_pem_x509_certificate(part.encode("utf-8"))
                    bundle_certs.append(c)
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "bundle cert parsing", e
                    )  # nosec B112: parsing loop tolerates invalid entries and continues
                    continue
            verified = False
            for ca in bundle_certs:
                if cert.issuer == ca.subject:
                    try:
                        pub = ca.public_key()
                        sig_hash = cert.signature_hash_algorithm
                        # Dispatch verify() based on key type: each key type in
                        # the cryptography library has a different verify() signature.
                        if isinstance(pub, RSAPublicKey):
                            if sig_hash is None:
                                raise SVIDValidationError("RSA cert has no signature hash algorithm")
                            pub.verify(
                                cert.signature,
                                cert.tbs_certificate_bytes,
                                padding.PKCS1v15(),
                                sig_hash,
                            )
                        elif isinstance(pub, EllipticCurvePublicKey):
                            if sig_hash is None:
                                raise SVIDValidationError("EC cert has no signature hash algorithm")
                            pub.verify(
                                cert.signature,
                                cert.tbs_certificate_bytes,
                                ECDSA(sig_hash),
                            )
                        elif isinstance(pub, DSAPublicKey):
                            if sig_hash is None:
                                raise SVIDValidationError("DSA cert has no signature hash algorithm")
                            pub.verify(
                                cert.signature,
                                cert.tbs_certificate_bytes,
                                sig_hash,
                            )
                        elif isinstance(pub, (Ed25519PublicKey, Ed448PublicKey)):
                            pub.verify(cert.signature, cert.tbs_certificate_bytes)
                        else:
                            raise SVIDValidationError(f"Unsupported CA public key type: {type(pub).__name__}")
                        verified = True
                        break
                    except SVIDValidationError:
                        raise
                    except Exception as e:
                        from runtime.util.best_effort import swallow_optional

                        swallow_optional(
                            "bundle cert verify", e
                        )  # nosec B112: parsing loop tolerates invalid entries and continues
                        continue

            if not verified:
                raise SVIDValidationError("bundle validation failed: could not verify certificate against bundle")

        return spiffe_id, identity_hash
    except SVIDValidationError:
        raise
    except Exception as e:
        raise SVIDValidationError(f"Unexpected SVID parsing error: {e}") from e
