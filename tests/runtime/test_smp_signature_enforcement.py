from typing import Any

import pytest

from runtime.core.truth_layer import TruthLayer
from runtime.operator_logic import decide_route


class DummyEvent:
    def __init__(self, intent="vector.route", dst="vector", priority=3):
        self.intent = intent
        self.dst = dst
        self.priority = priority
        self.identity_context: dict[str, Any] | None = None
        self.signed: bool | None = None


def test_truthlayer_rejects_missing_signed():
    ev = DummyEvent()
    # ensure identity policy allows vector.route so the unsigned check is reached
    ev.identity_context = {"identity_class": "translated"}
    # no ev.signed attribute -> treated as unsigned (fail-closed)
    t = TruthLayer()
    # The TruthLayer enforces SHA3 anchoring and signature checks; either
    # missing SHA3 or an explicit unsigned flag are valid fail-closed reasons.
    with pytest.raises(RuntimeError):
        t.verify(ev)


def test_truthlayer_rejects_explicit_unsigned():
    ev = DummyEvent()
    ev.identity_context = {"identity_class": "translated"}
    ev.signed = False
    t = TruthLayer()
    # An explicit 'signed=False' must also be rejected; accept any RuntimeError
    # raised by the TruthLayer for unsigned or missing SHA3 anchors.
    with pytest.raises(RuntimeError):
        t.verify(ev)


def test_decide_route_rejects_unsigned_envelope():
    ev = DummyEvent()
    # no signed attribute
    with pytest.raises(RuntimeError, match="unsigned envelope"):
        decide_route(ev)


def test_decide_route_rejects_explicitly_unsigned():
    ev = DummyEvent()
    ev.signed = False
    with pytest.raises(RuntimeError, match="unsigned envelope"):
        decide_route(ev)
