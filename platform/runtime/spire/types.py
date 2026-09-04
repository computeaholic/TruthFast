"""Type protocols for SPIRE workload identity types."""

from __future__ import annotations

from typing import List, Protocol


class X509SVID(Protocol):
    """Protocol for an X.509 SVID returned by the SPIRE Workload API."""

    cert_chain: List[bytes]
    private_key: bytes


class WorkloadClient(Protocol):
    """Protocol for a SPIRE Workload API client."""

    def fetch_x509_svid(self) -> X509SVID: ...
