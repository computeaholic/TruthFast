from runtime.identity.context import IdentityContext


def extract_identity_context(context) -> IdentityContext:
    """Extract and parse SPIFFE identity from mTLS auth context.
    Raises exception if identity is missing, malformed, or unauthenticated.
    """
    try:
        auth_ctx = context.auth_context()
        spiffe_id = None
        for key, values in auth_ctx.items():
            if key == "x509_common_name" and values:
                spiffe_id = values[0].decode()
                break

        if not spiffe_id:
            raise ValueError("SPIFFE identity missing from mTLS context")

        # Parse SPIFFE ID: spiffe://trust_domain/ns/namespace/sa/service_account/tier
        if not spiffe_id.startswith("spiffe://"):
            raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

        parts = spiffe_id[len("spiffe://") :].split("/")
        if len(parts) < 5:
            raise ValueError(f"Malformed SPIFFE ID: {spiffe_id}")

        trust_domain = parts[0]
        if parts[1] != "ns":
            raise ValueError(f"Expected 'ns' in SPIFFE ID: {spiffe_id}")
        namespace = parts[2]
        if parts[3] != "sa":
            raise ValueError(f"Expected 'sa' in SPIFFE ID: {spiffe_id}")
        service_account = parts[4]
        tier = parts[5] if len(parts) > 5 else ""

        return IdentityContext(
            spiffe_id=spiffe_id,
            trust_domain=trust_domain,
            tier=tier,
            namespace=namespace,
            service_account=service_account,
            attested=True,  # Came from mTLS
        )

    except Exception as e:
        raise ValueError(f"Failed to extract valid SPIFFE identity: {e}") from e
