from runtime.actions.example import example_action
from runtime.api.grpc_server import serve

if __name__ == "__main__":
    serve(handler=example_action, port=50051)
