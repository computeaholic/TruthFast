from __future__ import annotations

from runtime.contracts.forgesec_contract import (
    REQUIRED_FIELDS,
    TL_V1_FORGESEC,
)

# Backward-compat names used in existing runtime/tests.
FORGESEC_TRUTHLAYER_SOURCE = TL_V1_FORGESEC
FORGESEC_REQUIRED_FIELDS = tuple(REQUIRED_FIELDS)
