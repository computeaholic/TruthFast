# SPIFFE identity extraction utilities
#
# NOTE: This local package intentionally shadows the PyPI `spiffe` package.
# The only cross-package import is `WorkloadApiClient` which lives in the
# installed `spiffe` distribution. We stub it here so mypy does not raise
# attr-defined errors when spire/grpc_client.py imports it inside a
# try/except (the import will fail at runtime if pyspiffe is not available,
# setting PYSPIFFE_AVAILABLE = False).
from __future__ import annotations

from typing import Any

# Stub: the real class lives in the pyspiffe distribution.  spire/grpc_client.py
# imports it inside a try/except; if the import fails PYSPIFFE_AVAILABLE is set
# to False and the attribute is never used.
WorkloadApiClient: Any = None
