"""Telemetry identity binding is mandatory.
Observability obeys the same identity and policy constraints as execution.
"""

import logging

from runtime.identity.context import IdentityContext


def extract_spiffe_from_envoy_metadata(envoy_context):
    """Extract SPIFFE ID from Envoy metadata (legacy compatibility)."""
    try:
        return envoy_context["peer_metadata"]["spiffe_id"]
    except Exception as e:
        logging.getLogger(__name__).debug("Failed to extract spiffe id from envoy metadata: %s", e, exc_info=True)
        return None


def extract_identity_context_from_envoy_metadata(envoy_context) -> IdentityContext | None:
    """Extract full IdentityContext from Envoy metadata.

    Phase 7: Telemetry must use IdentityContext for attribution.

    Security: This helper is strictly a metadata parser and MUST NOT imply
    attestation. The returned IdentityContext MUST have `attested=False`.
    Malformed or untrusted SPIFFE IDs are rejected (return None).
    """
    try:
        spiffe_id = envoy_context["peer_metadata"]["spiffe_id"]
        # Basic sanity: must start with spiffe:// and be properly structured
        parts = spiffe_id.split("/")
        if not (len(parts) >= 6 and parts[0] == "spiffe:" and parts[1] == ""):
            return None

        trust_domain = parts[2]
        if not trust_domain:
            return None

        namespace = parts[4] if len(parts) > 4 else "default"
        service_account = parts[6] if len(parts) > 6 else "default"

        # For metadata fallback, we MUST NOT infer attestation.
        attested = False
        tier = "system" if "operator" in service_account else "user"

        return IdentityContext(
            spiffe_id=spiffe_id,
            trust_domain=trust_domain,
            tier=tier,
            namespace=namespace,
            service_account=service_account,
            attested=attested,
        )
    except Exception as e:
        logging.getLogger(__name__).debug(
            "Failed to extract identity context from envoy metadata: %s", e, exc_info=True
        )
        return None
