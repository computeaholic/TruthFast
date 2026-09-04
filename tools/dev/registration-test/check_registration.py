#!/usr/bin/env python3
"""Check plugin registration socket and capture raw request/response.

Usage (run inside a pod that can access the host plugin socket at /host/plugins_registry):

$ python3 check_registration.py /host/plugins_registry/csi.spiffe.io-reg.sock

The script will:
 - generate python gRPC code from api.proto (requires grpc_tools)
 - call GetInfo and print proto and raw bytes
 - call NotifyRegistrationStatus (true) and print response
 - call NotifyRegistrationStatus (false) to show registrar error behavior

"""

import importlib
import os
import subprocess
import sys

try:
    import grpc
except Exception as e:
    print("Missing dependency 'grpc'. Install with: pip install grpcio grpcio-tools protobuf")
    raise

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROTO = os.path.join(SCRIPT_DIR, "api.proto")
GENERATED_PY = SCRIPT_DIR

if len(sys.argv) < 2:
    print("Usage: check_registration.py <unix-socket-path>")
    print("Example: check_registration.py /host/plugins_registry/csi.spiffe.io-reg.sock")
    sys.exit(2)

socket_path = sys.argv[1]
if not os.path.exists(PROTO):
    print("api.proto not found in", SCRIPT_DIR)
    sys.exit(1)

# Generate python bindings in the same dir
print("[*] Generating python protobuf grpc code from api.proto")
protoc_cmd = [
    sys.executable,
    "-m",
    "grpc_tools.protoc",
    "-I",
    SCRIPT_DIR,
    "--python_out",
    GENERATED_PY,
    "--grpc_python_out",
    GENERATED_PY,
    PROTO,
]
ret = subprocess.run(protoc_cmd, capture_output=True)
if ret.returncode != 0:
    print("protoc failed:\n", ret.stdout.decode(), ret.stderr.decode())
    sys.exit(1)

sys.path.insert(0, GENERATED_PY)
reg_pb2 = importlib.import_module("api_pb2")
reg_pb2_grpc = importlib.import_module("api_pb2_grpc")

# Build channel
target = "unix://" + socket_path
print(f"[*] Connecting to {target}")
channel = grpc.insecure_channel(target)

# Wait for connection ready up to 5s
try:
    grpc.channel_ready_future(channel).result(timeout=5)
    print("[*] channel ready")
except Exception as e:
    print("[!] channel not ready within 5s:", repr(e))

stub = reg_pb2_grpc.RegistrationStub(channel)


# Helper to print raw bytes and structured message
def dump_msg(msg, label):
    try:
        raw = msg.SerializeToString()
        print(f"--- {label} (len={len(raw)} bytes) ---")
        print(msg)
        print("raw hex:\n", raw.hex())
    except Exception as e:
        print(f"Error serializing {label}:", e)


# 1) GetInfo
print("\n==> Calling GetInfo()")
try:
    req = reg_pb2.InfoRequest()
    resp = stub.GetInfo(req, timeout=5)
    dump_msg(resp, "GetInfo response")
    print("supported_versions (as list):", list(resp.supported_versions))
except grpc.RpcError as e:
    print("gRPC error calling GetInfo:")
    print("  code:", e.code())
    print("  details:", e.details())
    # underlying exception text sometimes appears in e.args
    print("  args:", e.args)

# 2) NotifyRegistrationStatus(true)
print("\n==> Calling NotifyRegistrationStatus(plugin_registered=true)")
try:
    req = reg_pb2.RegistrationStatus(plugin_registered=True, error="")
    resp = stub.NotifyRegistrationStatus(req, timeout=5)
    dump_msg(resp, "NotifyRegistrationStatus response")
    print("NotifyRegistrationStatus completed OK")
except grpc.RpcError as e:
    print("gRPC error on NotifyRegistrationStatus(true):")
    print("  code:", e.code())
    print("  details:", e.details())
    print("  args:", e.args)

# 3) NotifyRegistrationStatus(false) - expected to cause registrar to exit if backend handles it that way
print("\n==> Calling NotifyRegistrationStatus(plugin_registered=false) " "(this may crash the registrar)")
try:
    req = reg_pb2.RegistrationStatus(plugin_registered=False, error="simulated failure")
    resp = stub.NotifyRegistrationStatus(req, timeout=5)
    dump_msg(resp, "NotifyRegistrationStatus(false) response")
    print("NotifyRegistrationStatus(false) completed OK (unexpected)")
except grpc.RpcError as e:
    print("gRPC error on NotifyRegistrationStatus(false):")
    print("  code:", e.code())
    print("  details:", e.details())
    print("  args:", e.args)

print("\nDone.")
