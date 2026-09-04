import api_pb2
import api_pb2_grpc
import grpc

ch = "unix:///host/plugins_registry/csi.spiffe.io-reg.sock"
print("connecting to", ch, flush=True)
channel = grpc.insecure_channel(ch)
try:
    grpc.channel_ready_future(channel).result(timeout=5)
    print("channel ready", flush=True)
except Exception as e:
    print("channel not ready", repr(e), flush=True)
try:
    stub = api_pb2_grpc.RegistrationStub(channel)
    resp = stub.GetInfo(api_pb2.InfoRequest(), timeout=5)
    print("GetInfo response:", resp, flush=True)
    print("supported_versions:", list(resp.supported_versions), flush=True)
except Exception as e:
    print("GetInfo failed:", repr(e), flush=True)
