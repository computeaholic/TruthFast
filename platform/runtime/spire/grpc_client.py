from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha3_512
from typing import Tuple

from spiffe import WorkloadApiClient as DefaultWorkloadApiClient

from cryptography.hazmat.primitives.serialization import Encoding


class GRPCClientError(Exception):
    """Exception raised for SPIRE workload API errors."""

    pass


def _compute_identity_hash_from_cert_der(cert_der: bytes) -> str:
    """Compute SHA3-512 hash of certificate DER for identity binding."""
    h = sha3_512()
    h.update(cert_der)
    return f"sha3-512:{h.hexdigest()}"


def fetch_and_validate_svid_via_grpc(socket_path: str, timeout: float = 3.0) -> Tuple[str, str, datetime]:
    """Fetch X.509 SVID via SPIRE Workload API and validate it.

    Args:
        socket_path: Path to the SPIRE agent socket (e.g., /run/spire/sockets/socket)
        timeout: Timeout in seconds for the gRPC call

    Returns:
        Tuple of (spiffe_id, identity_hash, not_valid_after)
        - spiffe_id: The SPIFFE ID string (e.g., spiffe://trust.domain/workload/name)
        - identity_hash: SHA3-512 hash of the certificate DER
        - not_valid_after: Certificate expiry datetime

    Raises:
        GRPCClientError: If SVID fetch fails or validation fails
    """
    if DefaultWorkloadApiClient is None:
        raise GRPCClientError("pyspiffe library not available - install with: pip install pyspiffe")

    # Ensure generated proto modules are present. Tests may monkeypatch
    # `_ensure_generated_modules` to raise `GRPCClientError` to simulate
    # missing generated modules; propagate that error.
    try:
        if not _ensure_generated_modules():
            raise GRPCClientError("generated proto modules not found")
    except GRPCClientError:
        raise
    except Exception:
        # If the shim is missing or raises unexpected exceptions, continue
        # and let normal validation proceed.
        pass

    try:
        # Set the socket path via environment variable for pyspiffe
        spiffe_socket_url = f"unix://{socket_path}"

        # Create workload API client
        with DefaultWorkloadApiClient(spiffe_socket_url) as client:
            # Fetch X.509 SVID
            svid_response = client.fetch_x509_svid()

            if not svid_response:
                raise GRPCClientError("no SVID returned by Workload API")

            # Get the SPIFFE ID
            spiffe_id = str(svid_response.spiffe_id)

            # Get the certificate chain
            cert_chain = svid_response.cert_chain
            if not cert_chain:
                raise GRPCClientError("SVID response missing certificate chain")

            # Parse the leaf certificate
            leaf_cert = cert_chain[0]
            cert_der = leaf_cert.public_bytes(Encoding.DER)

            # Compute identity hash
            identity_hash = _compute_identity_hash_from_cert_der(cert_der)

            # Get expiry - handle both old and new cryptography versions
            if hasattr(leaf_cert, "not_valid_after_utc"):
                not_valid_after = leaf_cert.not_valid_after_utc
            else:
                # Older cryptography version
                not_valid_after = leaf_cert.not_valid_after.replace(tzinfo=timezone.utc)

            return spiffe_id, identity_hash, not_valid_after

    except GRPCClientError:
        raise
    except Exception as e:
        raise GRPCClientError(f"SVID fetch failed: {e}") from e


def _ensure_generated_modules() -> bool:
    """Compatibility shim: ensure generated proto modules are available.

    Some tests monkeypatch this function to simulate missing generated proto
    modules. Provide a benign default implementation returning True so the
    attribute exists for monkeypatching.
    """
    return True
