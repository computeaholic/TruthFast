#!/usr/bin/env python3
import os
import sys
import time
from concurrent import futures

import api_pb2
import api_pb2_grpc
import grpc


class RegServicer(api_pb2_grpc.RegistrationServicer):
    def GetInfo(self, request, context):
        print('GetInfo called, returning supported_versions=["1.0.0"]')
        # Construct PluginInfo across multiple lines to avoid long-line lint errors
        # and add a mypy/pylance ignore for dynamic protobuf-generated attributes.
        return api_pb2.PluginInfo(
            type="CSIPlugin",
            name="csi.spiffe.io",
            endpoint="/var/lib/kubelet/plugins_registry/csi.spiffe.io-reg.sock",
            supported_versions=["1.0.0"],  # type: ignore[attr-defined]
        )

    def NotifyRegistrationStatus(self, request, context):
        print("NotifyRegistrationStatus called:", request)
        # Always return success. Add type ignore for generated symbol resolution.
        return api_pb2.RegistrationStatusResponse()  # type: ignore[attr-defined]


def serve(socket_path):
    # Ensure directory exists
    d = os.path.dirname(socket_path)
    if not os.path.exists(d):
        os.makedirs(d, exist_ok=True)

    # Remove existing socket file if exists
    try:
        if os.path.exists(socket_path):
            os.remove(socket_path)
    except Exception as e:
        print("Could not remove existing socket:", e)

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    api_pb2_grpc.add_RegistrationServicer_to_server(RegServicer(), server)
    server.add_insecure_port("unix:" + socket_path)
    server.start()
    print("Listening on unix:" + socket_path)
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        server.stop(0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: stub_server.py <unix-socket-path>")
        sys.exit(2)
    serve(sys.argv[1])
