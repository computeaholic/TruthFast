import builtins
import importlib
import sys

import pytest

# Unit test: ensure bootstrap gracefully handles missing OpenTelemetry and leaves a safe no-op


def test_init_telemetry_is_noop_when_opentelemetry_missing(monkeypatch):
    # Ensure import of "opentelemetry" raises ImportError during module import
    real_import = builtins.__import__

    def fake_import(name, globals=None, locals=None, fromlist=(), level=0):
        if name == "opentelemetry" or name.startswith("opentelemetry."):
            raise ImportError("simulated missing opentelemetry")
        return real_import(name, globals, locals, fromlist, level)

    monkeypatch.setattr(builtins, "__import__", fake_import)

    # Remove module from sys.modules to force fresh import
    saved = {k: sys.modules.pop(k) for k in list(sys.modules) if k.startswith("opentelemetry")}

    try:
        # Import (or reload) the module under test
        mod = importlib.reload(importlib.import_module("runtime.telemetry.bootstrap"))
    finally:
        # Restore import behavior and modules
        monkeypatch.setattr(builtins, "__import__", real_import)
        for k, v in saved.items():
            sys.modules[k] = v

    # Concrete assertions: module indicates opentelemetry not available and trace is None
    if getattr(mod, "_otel_available", None) is not False:
        raise AssertionError("Expected _otel_available to be False when OpenTelemetry is missing")
    if getattr(mod, "trace", None) is not None:
        raise AssertionError("Expected trace to be None when OpenTelemetry is missing")

    # Calling init_telemetry should be a safe, observable no-op (trace remains None)
    mod.init_telemetry()
    if getattr(mod, "trace", None) is not None:
        raise AssertionError("Expected trace to be None after init_telemetry when OpenTelemetry missing")


pytestmark = pytest.mark.unit
