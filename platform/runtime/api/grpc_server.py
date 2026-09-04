import json

# Add proto directory to path for imports
import sys
from concurrent import futures
from uuid import UUID

import grpc
from grpc import ssl_server_credentials

sys.path.insert(0, "/Users/computeaholic/ThreadForge/runtime/api/proto")
import threadforge_execution_pb2 as pb
import threadforge_execution_pb2_grpc as pb_grpc

from runtime.execution import ExecutionDenied, ExecutionEscalated, ExecutionRequest, execute
from runtime.spiffe.extract import extract_identity_context


class ExecutionService(pb_grpc.ExecutionServiceServicer):
    def __init__(self, handler):
        self._handler = handler

    def Execute(self, request: pb.ExecuteRequest, context):
        try:
            # 🔐 Extract identity from SPIFFE mTLS cert
            identity = extract_identity_context(context)

            exec_req = ExecutionRequest(
                request_id=UUID(request.request_id),
                actor_identity=identity,
                identity_class=request.identity_class,
                action=request.action,
                resource=request.resource,
                payload=json.loads(request.payload_json.decode("utf-8")),
            )

            result = execute(exec_req, self._handler)

            return pb.ExecuteResponse(
                request_id=str(result.request_id),
                outcome=result.outcome,
                result_json=json.dumps(result.result).encode("utf-8"),
            )

        except ExecutionDenied as e:
            context.set_code(grpc.StatusCode.PERMISSION_DENIED)
            context.set_details(str(e))
            return pb.ExecuteResponse()

        except ExecutionEscalated as e:
            context.set_code(grpc.StatusCode.FAILED_PRECONDITION)
            context.set_details(str(e))
            return pb.ExecuteResponse()

        except Exception as e:
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"Internal execution error: {e}")
            return pb.ExecuteResponse()


def serve(*, handler, port: int = 50051):
    with open("/run/spire/sockets/tls.key", "rb") as f:
        private_key = f.read()
    with open("/run/spire/sockets/tls.crt", "rb") as f:
        certificate_chain = f.read()

    server_creds = ssl_server_credentials([(private_key, certificate_chain)])

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    pb_grpc.add_ExecutionServiceServicer_to_server(ExecutionService(handler), server)

    server.add_secure_port(f"[::]:{port}", server_creds)
    server.start()
    server.wait_for_termination()
