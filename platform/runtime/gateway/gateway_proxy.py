# ==============================================================================
# ThreadForge PPIT Gateway - Reference Architecture Stub
# ==============================================================================
#
# ARCHITECTURAL REFERENCE ONLY - DO NOT USE IN PRODUCTION
#
# This module provides a gold-standard reference implementation of a PPIT Gateway
# proxy for architectural documentation and testing purposes. It performs NO
# actual network operations and returns deterministic stub responses.
#
# Runtime systems MUST implement their own proxy logic using this as a template.
# This stub exists solely for:
# - API contract documentation
# - Type system validation
# - Architectural reference
#
# DO NOT instantiate or call methods from this module in production code.
# ==============================================================================

from typing import Dict, Optional

from .gateway_context import IdentityContext
from .gateway_enforcer import EnforcementResult


class ProxyRequest:
    """Proxy request container."""

    def __init__(self, method: str, path: str, headers: Dict[str, str], body: Optional[bytes]):
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body


class ProxyResponse:
    """Proxy response container."""

    def __init__(self, status_code: int, headers: Dict[str, str], body: Optional[bytes]):
        self.status_code = status_code
        self.headers = headers
        self.body = body


class GatewayProxy:
    """
    PPIT Gateway proxy reference implementation.

    ⚠️  ARCHITECTURAL REFERENCE ONLY - DO NOT USE IN PRODUCTION ⚠️

    This class provides a complete type-safe interface and behavioral reference
    for implementing PPIT Gateway proxies. It performs NO actual network operations
    and returns deterministic stub responses for testing and documentation.

    Production implementations MUST:
    - Implement actual network forwarding logic
    - Handle real protocol translation
    - Perform proper error handling and retries
    - Integrate with observability systems

    This reference implementation exists solely for:
    - API contract documentation
    - Type system validation
    - Architectural reference and testing
    """

    def __init__(self):
        # ⚠️  REFERENCE ONLY - No actual initialization performed
        self._stub_responses = {
            "GET": ProxyResponse(200, {"Content-Type": "application/json"}, b'{"status": "reference_implementation"}'),
            "POST": ProxyResponse(201, {"Content-Type": "application/json"}, b'{"created": true}'),
            "PUT": ProxyResponse(204, {}, None),
            "DELETE": ProxyResponse(204, {}, None),
        }

    def forward_request(
        self, context: IdentityContext, enforcement: EnforcementResult, request: ProxyRequest
    ) -> ProxyResponse:
        """
        Forward request to legacy system (reference implementation).

        ⚠️  REFERENCE ONLY - No actual forwarding performed ⚠️

        This method demonstrates the expected interface and behavior for
        forwarding requests to legacy PPIT systems. Production implementations
        MUST perform actual network operations.

        Args:
            context: Validated identity context
            enforcement: Capability enforcement result
            request: Incoming proxy request

        Returns:
            Reference response (no actual forwarding occurs)
        """
        if not enforcement.allowed:
            return ProxyResponse(
                403,
                {"Content-Type": "application/json"},
                f'{{"error": "Access denied: {enforcement.reason}"}}'.encode(),
            )

        # Return deterministic stub response based on HTTP method
        return self._stub_responses.get(request.method, ProxyResponse(405, {}, b"Method not allowed"))

    def translate_identity_headers(self, context: IdentityContext) -> Dict[str, str]:
        """
        Translate ThreadForge identity context to legacy protocol headers (reference implementation).

        ⚠️  REFERENCE ONLY - No actual protocol translation performed ⚠️

        This method demonstrates the expected interface for translating
        ThreadForge identity context to legacy PPIT protocol headers.
        Production implementations MUST perform actual protocol translation.

        Args:
            context: Identity context to translate

        Returns:
            Reference headers (no actual translation occurs)
        """
        return {
            "X-ThreadForge-Spiffe-ID": context.spiffe_id,
            "X-ThreadForge-Workload": context.workload_name,
            "X-ThreadForge-Namespace": context.namespace,
            "X-ThreadForge-Timestamp": context.timestamp.isoformat(),
        }

    def validate_response_integrity(self, response: ProxyResponse) -> bool:
        """
        Validate response integrity from legacy system (reference implementation).

        ⚠️  REFERENCE ONLY - No actual validation performed ⚠️

        This method demonstrates the expected interface for validating
        responses from legacy PPIT systems. Production implementations
        MUST perform actual cryptographic validation.

        Args:
            response: Response from legacy system

        Returns:
            Always True (reference validation)
        """
        return True
