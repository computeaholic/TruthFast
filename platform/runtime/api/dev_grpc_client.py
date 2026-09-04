import json
import sys
from uuid import uuid4

import grpc

# Add proto directory to path for imports
sys.path.insert(0, "/Users/computeaholic/ThreadForge/runtime/api/proto")
import threadforge_execution_pb2 as pb
import threadforge_execution_pb2_grpc as pb_grpc


def main():
    channel = grpc.insecure_channel("localhost:50051")
    stub = pb_grpc.ExecutionServiceStub(channel)

    resp = stub.Execute(
        pb.ExecuteRequest(
            request_id=str(uuid4()),
            actor_identity="user:jeff",
            identity_class="native",
            action="example.run",
            resource="test.resource",
            payload_json=json.dumps({"hello": "grpc"}).encode("utf-8"),
        ),
    )

    print(resp)


if __name__ == "__main__":
    main()
