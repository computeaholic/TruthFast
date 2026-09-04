from uuid import uuid4

from runtime.actions.example import example_action
from runtime.api_adapter import handle_request

if __name__ == "__main__":
    response = handle_request(
        request_id=uuid4(),
        actor_identity="user:jeff",
        identity_class="native",
        action="example.run",
        resource="test.resource",
        payload={"hello": "world"},
        handler=example_action,
    )

    print(response)
