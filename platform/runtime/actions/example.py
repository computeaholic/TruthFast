from runtime.execution import ExecutionRequest


def example_action(req: ExecutionRequest) -> dict:
    # This is intentionally boring.
    # Real logic plugs in here later.
    return {
        "echo": req.payload,
        "resource": req.resource,
    }
