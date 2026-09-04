from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path


def _load_module(module_path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _write_registry(tmp_path: Path, *, active: str = "cosign_v1") -> tuple[Path, Path]:
    registry_path = tmp_path / "signing_key_registry.json"
    sig_path = tmp_path / "signing_key_registry.sig"
    cosign_v1_pub = tmp_path / "cosign_v1.pub"
    cosign_v1_priv = tmp_path / "cosign_v1.key"
    cosign_v2_pub = tmp_path / "cosign_v2.pub"
    cosign_v2_priv = tmp_path / "cosign_v2.key"
    cosign_v1_pub.write_text("dummy", encoding="utf-8")
    cosign_v1_priv.write_text("dummy", encoding="utf-8")
    cosign_v2_pub.write_text("dummy", encoding="utf-8")
    cosign_v2_priv.write_text("dummy", encoding="utf-8")
    sig_path.write_text("dummy", encoding="utf-8")

    payload = {
        "version": 1,
        "genesis_key_id": "cosign_v1",
        "active_key_id": active,
        "keys": {
            "cosign_v1": {
                "public_key_path": str(cosign_v1_pub),
                "private_key_path": str(cosign_v1_priv),
            },
            "cosign_v2": {
                "public_key_path": str(cosign_v2_pub),
                "private_key_path": str(cosign_v2_priv),
            },
        },
        "rotations": [],
    }
    registry_path.write_text(json.dumps(payload), encoding="utf-8")
    return registry_path, sig_path


def _set_registry_sig_env(sig_path: Path):
    old = os.environ.get("THREADFORGE_SIGNING_KEY_REGISTRY_SIG")
    os.environ["THREADFORGE_SIGNING_KEY_REGISTRY_SIG"] = str(sig_path)
    return old


def _restore_registry_sig_env(old: str | None) -> None:
    if old is None:
        os.environ.pop("THREADFORGE_SIGNING_KEY_REGISTRY_SIG", None)
    else:
        os.environ["THREADFORGE_SIGNING_KEY_REGISTRY_SIG"] = old


def test_structured_audit_event_written(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger")
    log_path = tmp_path / "audit.log"
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    old_sig_env = _set_registry_sig_env(sig_path)

    try:
        event = module.log_audit_event(
            actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
            actor_role="test-client",
            namespace="threadforge-test",
            action="HTTP_GET",
            resource="service/echo",
            result="ALLOW",
            reason="authorization_policy_match",
            signing_registry_path=str(registry_path),
            audit_log_path=str(log_path),
        )
    finally:
        _restore_registry_sig_env(old_sig_env)

    assert log_path.exists()
    lines = [line for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])

    required = {
        "timestamp",
        "actor_spiffe_id",
        "actor_role",
        "namespace",
        "action",
        "resource",
        "result",
        "reason",
        "breakglass",
        "signing_key_id",
    }
    assert required.issubset(parsed.keys())
    assert event["result"] == "ALLOW"
    assert event["breakglass"] is False
    assert event["request_groups"] == []
    assert event["signing_key_id"] == "cosign_v1"
    assert log_path.stat().st_mode & 0o777 == 0o640
    assert log_path.parent.stat().st_mode & 0o777 == 0o750


def test_breakglass_event_persisted_and_tagged(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_breakglass")
    log_path = tmp_path / "audit.log"
    registry_path, sig_path = _write_registry(tmp_path, active="cosign_v2")
    module._verify_cosign_blob = lambda **_: None
    old_sig_env = _set_registry_sig_env(sig_path)

    try:
        event = module.log_audit_event(
            actor_spiffe_id="user:kubernetes-admin",
            actor_role="breakglass-operator",
            namespace="kyverno",
            action="SCALE_DEPLOYMENT",
            resource="deployment/kyverno-admission-controller",
            result="ALLOW",
            reason="breakglass_emergency_override",
            breakglass=True,
            request_groups=["threadforge-breakglass"],
            signing_registry_path=str(registry_path),
            audit_log_path=str(log_path),
        )
    finally:
        _restore_registry_sig_env(old_sig_env)

    lines = [line for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["breakglass"] is True
    assert parsed["action"] == "SCALE_DEPLOYMENT"
    assert parsed["resource"] == "deployment/kyverno-admission-controller"
    assert event["breakglass"] is True
    assert event["request_groups"] == ["threadforge-breakglass"]
    assert event["signing_key_id"] == "cosign_v2"


def test_audit_event_missing_field_fails(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger")
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path=str(tmp_path / "audit.log"),
            )
        except module.AuditLoggingError:
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for missing actor_spiffe_id")


def test_untrusted_signing_key_rejected(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_key_reject")
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    log_path = tmp_path / "audit.log"
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_key_id="cosign_v999",
                signing_registry_path=str(registry_path),
                audit_log_path=str(log_path),
            )
        except module.AuditLoggingError:
            assert not log_path.exists() or log_path.read_text(encoding="utf-8").strip() == ""
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for untrusted signing_key_id")


def test_breakglass_group_without_flag_rejected(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_group_enforce")
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="user:kubernetes-admin",
                actor_role="breakglass-operator",
                namespace="kyverno",
                action="SCALE_DEPLOYMENT",
                resource="deployment/kyverno-admission-controller",
                result="ALLOW",
                reason="breakglass_emergency_override",
                request_groups=["threadforge-breakglass"],
                breakglass=False,
                signing_registry_path=str(registry_path),
                audit_log_path=str(tmp_path / "audit.log"),
            )
        except module.AuditLoggingError:
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError when breakglass group is present without breakglass=true")


def test_audit_write_failure_fails_closed(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_write_fail")
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    old_sig_env = _set_registry_sig_env(sig_path)
    # /dev/full always fails writes with ENOSPC on Linux; this proves fail-closed behavior.
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path="/dev/full",
            )
        except module.AuditLoggingError:
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError when audit sink write fails")


def test_corrupt_canonical_tail_rejected_and_no_append(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_corrupt_tail")
    registry_path, sig_path = _write_registry(tmp_path)
    module._verify_cosign_blob = lambda **_: None
    log_path = tmp_path / "audit.log"
    corrupt_tail = '{"not":"a complete event"'
    log_path.write_text(corrupt_tail + "\n", encoding="utf-8")
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path=str(log_path),
            )
        except module.AuditLoggingError as exc:
            assert "invalid JSON in canonical audit log tail" in str(exc)
            assert log_path.read_text(encoding="utf-8") == corrupt_tail + "\n"
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for corrupt canonical audit tail")


def test_missing_registry_signature_rejected_and_no_persist(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_missing_sig")
    registry_path, sig_path = _write_registry(tmp_path)
    sig_path.unlink(missing_ok=True)
    module._verify_cosign_blob = lambda **_: None
    log_path = tmp_path / "audit.log"
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path=str(log_path),
            )
        except module.AuditLoggingError:
            assert not log_path.exists() or log_path.read_text(encoding="utf-8").strip() == ""
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for missing signing key registry signature")


def test_invalid_rotation_chain_rejected_and_no_persist(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_bad_rotation")
    registry_path, sig_path = _write_registry(tmp_path, active="cosign_v2")
    reg = json.loads(registry_path.read_text(encoding="utf-8"))
    bad_sig = tmp_path / "rotation.sig"
    bad_sig.write_text("dummy", encoding="utf-8")
    reg["rotations"] = [
        {
            "from": "cosign_v2",
            "to": "cosign_v1",
            "signature_path": str(bad_sig),
        }
    ]
    registry_path.write_text(json.dumps(reg), encoding="utf-8")
    module._verify_cosign_blob = lambda **_: None
    log_path = tmp_path / "audit.log"
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path=str(log_path),
            )
        except module.AuditLoggingError:
            assert not log_path.exists() or log_path.read_text(encoding="utf-8").strip() == ""
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for invalid signing key rotation chain")


def test_tampered_registry_rejected_and_no_persist(tmp_path: Path) -> None:
    module = _load_module(Path("platform/runtime/audit/audit_logger.py"), "audit_logger_tampered_registry")
    registry_path, sig_path = _write_registry(tmp_path)
    registry_path.write_text("not-json", encoding="utf-8")
    module._verify_cosign_blob = lambda **_: None
    log_path = tmp_path / "audit.log"
    old_sig_env = _set_registry_sig_env(sig_path)
    try:
        try:
            module.log_audit_event(
                actor_spiffe_id="spiffe://threadforge/ns/threadforge-test/sa/test-client",
                actor_role="test-client",
                namespace="threadforge-test",
                action="HTTP_GET",
                resource="service/echo",
                result="ALLOW",
                reason="authorization_policy_match",
                signing_registry_path=str(registry_path),
                audit_log_path=str(log_path),
            )
        except module.AuditLoggingError:
            assert not log_path.exists() or log_path.read_text(encoding="utf-8").strip() == ""
            return
    finally:
        _restore_registry_sig_env(old_sig_env)
    raise AssertionError("expected AuditLoggingError for tampered signing key registry")
