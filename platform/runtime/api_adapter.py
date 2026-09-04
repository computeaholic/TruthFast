from collections.abc import Callable
from typing import Any
from uuid import UUID

from runtime.execution import ExecutionRequest, execute


def handle_request(
    *,
    request_id: UUID,
    actor_identity: str,
    identity_class: str,
    action: str,
    resource: str,
    payload: dict[str, Any],
    handler: Callable[[ExecutionRequest], dict[str, Any]],
) -> dict[str, Any]:
    """Framework-agnostic request entry point."""
    req = ExecutionRequest(
        request_id=request_id,
        actor_identity=actor_identity,
        identity_class=identity_class,
        action=action,
        resource=resource,
        payload=payload,
    )

    result = execute(req, handler)

    return {
        "request_id": str(result.request_id),
        "outcome": result.outcome,
        "result": result.result,
    }
