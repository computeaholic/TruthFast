import datetime
import importlib.util
import os
import sys
import types

import pytest

pytestmark = pytest.mark.unit

# Import gateway support modules by path and register them under package names so
# relative imports in the proxy module succeed.
base = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "platform", "runtime", "gateway"))

# Create a dummy package module so relative imports in the gateway modules do not
# trigger the runtime.gateway package __init__ that intentionally raises.
pkg = types.ModuleType("runtime.gateway")
pkg.__path__ = [base]

sys.modules["runtime.gateway"] = pkg

enforcer_path = os.path.join(base, "gateway_enforcer.py")
enf_spec = importlib.util.spec_from_file_location("runtime.gateway.gateway_enforcer", enforcer_path)
assert enf_spec is not None, "failed to load spec for gateway_enforcer"
enf = importlib.util.module_from_spec(enf_spec)
assert enf_spec.loader is not None, "no loader for gateway_enforcer spec"
enf_spec.loader.exec_module(enf)
sys.modules["runtime.gateway.gateway_enforcer"] = enf

context_path = os.path.join(base, "gateway_context.py")
ctx_spec = importlib.util.spec_from_file_location("runtime.gateway.gateway_context", context_path)
assert ctx_spec is not None, "failed to load spec for gateway_context"
ctx = importlib.util.module_from_spec(ctx_spec)
assert ctx_spec.loader is not None, "no loader for gateway_context spec"
ctx_spec.loader.exec_module(ctx)
sys.modules["runtime.gateway.gateway_context"] = ctx

proxy_path = os.path.join(base, "gateway_proxy.py")
spec = importlib.util.spec_from_file_location("runtime.gateway.gateway_proxy", proxy_path)
assert spec is not None, "failed to load spec for gateway_proxy"
gw = importlib.util.module_from_spec(spec)
assert spec.loader is not None, "no loader for gateway_proxy spec"
spec.loader.exec_module(gw)
GatewayProxy = gw.GatewayProxy
ProxyRequest = gw.ProxyRequest
ProxyResponse = gw.ProxyResponse

# Import support types from the loaded modules
EnforcementResult = enf.EnforcementResult
IdentityContext = ctx.IdentityContext


def test_gateway_proxy_denied():
    gp = GatewayProxy()
    enforcement = EnforcementResult(allowed=False, reason="insufficient", required_caps=[])
    req = ProxyRequest("GET", "/", {}, None)
    ctx = IdentityContext(
        spiffe_id="spiffe://x",
        trust_domain="identity.threadforge.local",
        workload_name="w",
        namespace="n",
        capabilities={"read": True, "write": True, "execute": True},
        delegation_chain=["a"],
        timestamp=datetime.datetime.now(datetime.timezone.utc),
    )
    resp = gp.forward_request(ctx, enforcement, req)
    assert resp.status_code == 403
    assert b"Access denied" in resp.body


def test_gateway_proxy_get_allowed():
    gp = GatewayProxy()
    enforcement = EnforcementResult(allowed=True, reason="ok", required_caps=["read"])
    req = ProxyRequest("GET", "/", {}, None)
    ctx = IdentityContext(
        spiffe_id="spiffe://x",
        trust_domain="identity.threadforge.local",
        workload_name="w",
        namespace="n",
        capabilities={"read": True, "write": True, "execute": True},
        delegation_chain=["a"],
        timestamp=datetime.datetime.now(datetime.timezone.utc),
    )
    resp = gp.forward_request(ctx, enforcement, req)
    assert resp.status_code == 200
    assert b"reference_implementation" in resp.body


def test_translate_identity_headers():
    gp = GatewayProxy()
    ctx = IdentityContext(
        spiffe_id="spiffe://x",
        trust_domain="identity.threadforge.local",
        workload_name="w",
        namespace="n",
        capabilities={"read": True},
        delegation_chain=["a"],
        timestamp=datetime.datetime.now(datetime.timezone.utc),
    )
    headers = gp.translate_identity_headers(ctx)
    assert headers["X-ThreadForge-Spiffe-ID"] == "spiffe://x"
    assert headers["X-ThreadForge-Workload"] == "w"
    assert headers["X-ThreadForge-Namespace"] == "n"
    assert "X-ThreadForge-Timestamp" in headers
