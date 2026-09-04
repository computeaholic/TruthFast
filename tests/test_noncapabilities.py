import importlib
import os
import sys
import types

import pytest

# Provide a local grpc shim for test environments where grpc is not installed.
# The generated gRPC skeletons import grpc and inspect __version__ and may import
# grpc._utilities.first_version_is_lower; provide a minimal shim (ModuleType) to
# allow tests to exercise servicer method behavior without installing grpc.
# NOTE: This is a documented unit boundary — the shim is intentionally minimal
# and used only for unit tests that exercise local behavior. It is NOT an
# integration test and does not replace the need for a real grpc test where
# contract-level validation is required.

pytestmark = pytest.mark.unit
# The generated gRPC skeletons import grpc and inspect __version__ and may import
# grpc._utilities.first_version_is_lower; provide a minimal shim (ModuleType) to
# allow tests to exercise servicer method behavior without installing grpc.
# NOTE: This is a documented unit boundary — the shim is intentionally minimal
# and used only for unit tests that exercise local behavior. It is NOT an
# integration test and does not replace the need for a real grpc test where
# contract-level validation is required.
try:
    import grpc  # type: ignore[import-not-found,import-untyped]
except Exception:
    grpc_mod = types.ModuleType("grpc")
    # Avoid setattr with constant keys to satisfy static analyzers — write directly to __dict__
    grpc_mod.__dict__["__version__"] = "0.0.0"
    grpc_mod.__dict__["StatusCode"] = types.SimpleNamespace(UNIMPLEMENTED=0)
    grpc_mod.__dict__["experimental"] = types.SimpleNamespace(unary_unary=lambda *a, **k: None)
    grpc_mod.__dict__["_utilities"] = types.SimpleNamespace(first_version_is_lower=lambda a, b: False)
    sys.modules["grpc"] = grpc_mod
    grpc = grpc_mod

executor_mod = importlib.import_module("runtime.actuator.executor")
ActuatorExecutor = executor_mod.ActuatorExecutor
proposal_mod = importlib.import_module("runtime.actuation.proposal")
ActuationProposal = proposal_mod.ActuationProposal
ticket_mod = importlib.import_module("runtime.actuator.ticket_bridge")
TicketBridge = ticket_mod.TicketBridge
identity_mod = importlib.import_module("runtime.identity.identity")
IdentityProvider = identity_mod.IdentityProvider
# Ensure generated proto modules are importable by adding the proto directory to sys.path

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROTO_DIR = os.path.join(REPO_ROOT, "runtime", "api", "proto")
if PROTO_DIR not in sys.path:
    sys.path.insert(0, PROTO_DIR)


class DummyContext:
    def __init__(self):
        self.code = None
        self.details = None

    def set_code(self, code):
        self.code = code

    def set_details(self, details):
        self.details = details


def test_executor_intentional_noncapability(monkeypatch):
    # Allow execution gate to return True to reach the intentional non-capability
    monkeypatch.setattr("runtime.actuator.gate.ActuatorGate.is_execution_allowed", lambda self: True)

    ex = ActuatorExecutor()
    proposal = ActuationProposal.new(
        source="test",
        reflex_action="noop",
        severity="low",
        plan={"plan_id": "p-1"},
        justification={"why": "test"},
    )

    with pytest.raises(RuntimeError) as exc:
        ex.execute(proposal)
    assert "Intentional non-capability" in str(exc.value)


def test_ticket_bridge_unknown_backend_raises():
    tb = TicketBridge()
    plan = {"plan_id": "p-2", "ticket_backend": "nope"}
    with pytest.raises(RuntimeError) as exc:
        tb.create_ticket(plan)
    assert "Intentional non-capability" in str(exc.value)


def test_ticket_bridge_log_backend_prints(capsys):
    tb = TicketBridge()
    plan = {"plan_id": "p-3", "ticket_backend": "log", "intent": "test"}
    tb.create_ticket(plan)
    captured = capsys.readouterr()
    assert "[TICKET] Review required for plan p-3" in captured.out


def test_identity_provider_interface_raises():
    ip = IdentityProvider()
    with pytest.raises(NotImplementedError):
        ip.current()


# Note: tests for generated gRPC servicers are intentionally omitted here to avoid
# introducing a dependency on the protobuf runtime in the local test environment.
# Generated server skeletons are documented in their files and in docs/NON_CAPABILITIES.md.
