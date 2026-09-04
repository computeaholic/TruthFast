from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "trust" / "trust_authority.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("trust_authority_test_module", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _active_cert(module):
    return module.CertDetails(
        pem="-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n",
        fingerprint_sha256="active-fp",
        fingerprint_sha3_256="active-fp3",
        serial="fd487b",
        subject="CN=active-root,O=SPIFFE,C=US",
        issuer="CN=active-root,O=SPIFFE,C=US",
        not_before="2026-06-06T02:20:29Z",
        not_after="2026-06-07T02:20:39Z",
        not_before_epoch=1,
        not_after_epoch=9999999999,
        ski="active-ski",
        aki="",
    )


def _envoy_certs_payload(*, root_serial: str = "fd487b", leaf_serial: str = "leaf-serial") -> str:
    return json.dumps(
        {
            "certificates": [
                {
                    "ca_cert": [
                        {
                            "serial_number": root_serial,
                            "subject_alt_names": [{"uri": "spiffe://identity.threadforge.local"}],
                        }
                    ],
                    "cert_chain": [
                        {
                            "serial_number": leaf_serial,
                            "subject_alt_names": [
                                {
                                    "uri": (
                                        "spiffe://identity.threadforge.local/ns/istio-system/"
                                        "sa/istio-ingressgateway"
                                    )
                                }
                            ],
                            "valid_from": "2026-06-06T00:00:00Z",
                            "expiration_time": "2026-06-07T00:00:00Z",
                        }
                    ],
                }
            ]
        }
    )


def test_ingress_consumer_uses_in_pod_envoy_observation_and_active_serial(monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    monkeypatch.setattr(module, "_first_ready_pod", lambda namespace, selector: "gateway-abc")
    commands: list[list[str]] = []

    def fake_exec(namespace, pod, command, container=None):
        commands.append(command)
        assert namespace == "istio-system"
        assert pod == "gateway-abc"
        assert container == "istio-proxy"
        return _envoy_certs_payload()

    monkeypatch.setattr(module, "_kubectl_exec", fake_exec)

    row = module._collect_ingressgateway_consumer(active)

    assert row["source"] == "envoy-admin:/certs"
    assert row["observation_status"] == "OBSERVED"
    assert row["present"] is True
    assert row["lineage_matches_active_root"] is True
    assert row["root_serial"] == "fd487b"
    assert commands == [["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:15000/certs"]]


def test_ingress_observation_failure_is_unobservable_without_restart_authority(monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    monkeypatch.setattr(module, "_first_ready_pod", lambda namespace, selector: "gateway-abc")

    def failed_exec(*args, **kwargs):
        raise RuntimeError("kubectl exec timed out")

    monkeypatch.setattr(module, "_kubectl_exec", failed_exec)

    row = module._collect_ingressgateway_consumer(active)

    assert row["present"] is True
    assert row["observation_status"] == "UNOBSERVABLE"
    assert row["lineage_matches_active_root"] is False
    assert row["restart_required"] is False
    assert row["remediation_target"] == ""


def test_ingress_pod_discovery_failure_is_not_reported_as_absence(monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    monkeypatch.setattr(
        module,
        "_first_ready_pod",
        lambda namespace, selector: (_ for _ in ()).throw(RuntimeError("kubectl unavailable")),
    )

    row = module._collect_ingressgateway_consumer(active)

    assert row["present"] is True
    assert row["observation_status"] == "UNOBSERVABLE"
    assert row["restart_required"] is False
    assert row["remediation_target"] == ""


def test_ingress_consumer_marks_stale_envoy_root_without_authorizing_restart(monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    monkeypatch.setattr(module, "_first_ready_pod", lambda namespace, selector: "gateway-abc")
    monkeypatch.setattr(module, "_kubectl_exec", lambda *args, **kwargs: _envoy_certs_payload(root_serial="old-root"))

    row = module._collect_ingressgateway_consumer(active)

    assert row["observation_status"] == "OBSERVED"
    assert row["present"] is True
    assert row["lineage_matches_active_root"] is False
    assert row["restart_required"] is True
    assert row["remediation_target"] == "deployment/istio-ingressgateway"


def test_export_state_marks_publication_and_consumer_convergence(tmp_path: Path, monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    source_rows = {
        "spire-ca-root-cert": {"name": "spire-ca-root-cert", "present": True, "fingerprint_sha256": "active-fp", "fingerprint_sha3_256": "x", "serial": "fd487b", "not_before": "", "not_after": "", "ski": "", "aki": ""},
        "istio-ca-root-cert": {"name": "istio-ca-root-cert", "present": True, "fingerprint_sha256": "active-fp", "fingerprint_sha3_256": "x", "serial": "fd487b", "not_before": "", "not_after": "", "ski": "", "aki": ""},
        "istiod-mounted-root": {"name": "istiod-mounted-root", "present": True, "fingerprint_sha256": "active-fp", "fingerprint_sha3_256": "x", "serial": "fd487b", "not_before": "", "not_after": "", "ski": "", "aki": ""},
        "workload-mounted-root": {"name": "workload-mounted-root", "present": True, "fingerprint_sha256": "active-fp", "fingerprint_sha3_256": "x", "serial": "fd487b", "not_before": "", "not_after": "", "ski": "", "aki": ""},
    }
    consumer_rows = {
        "istiod": {
            "name": "istiod",
            "namespace": "istio-system",
            "kind": "deployment",
            "remediation_target": "deployment/istiod",
            "pod": "istiod-abc",
            "source": "secret:istiod-tls",
            "present": True,
            "lineage_matches_active_root": True,
            "signer_chains_to_active_root": True,
            "leaf_chains_to_active_root": True,
            "root_matches_active_root": True,
            "restart_required": False,
            "error": "",
        },
        "istio-ingressgateway": {
            "name": "istio-ingressgateway",
            "namespace": "istio-system",
            "kind": "deployment",
            "remediation_target": "deployment/istio-ingressgateway",
            "pod": "gateway-abc",
            "source": "envoy-sds",
            "present": True,
            "lineage_matches_active_root": True,
            "signer_chains_to_active_root": True,
            "leaf_chains_to_active_root": True,
            "root_matches_active_root": True,
            "restart_required": False,
            "error": "",
        },
    }

    monkeypatch.setattr(module, "_utc_now", lambda: module.datetime(2026, 6, 6, 16, 0, 0, tzinfo=module.timezone.utc))
    monkeypatch.setattr(module, "_collect_active_root", lambda: (active, 4, 2))
    monkeypatch.setattr(module, "_collect_active_root_bundle", lambda: ("bundle-text", active, 4, 2))
    monkeypatch.setattr(module, "_safe_collect", lambda name, collector: dict(source_rows[name]))
    monkeypatch.setattr(module, "_safe_collect_consumer", lambda name, collector, active_cert: dict(consumer_rows[name]))

    state_path = tmp_path / "state.json"
    metrics_path = tmp_path / "metrics.prom"
    counters_path = tmp_path / "counters.json"
    counters_path.write_text(json.dumps({"success_total": 1, "failure_total": 0, "last_result": "success", "last_run_epoch": 10}), encoding="utf-8")

    assert module.export_state(state_path, metrics_path, counters_path) == 0
    state = json.loads(state_path.read_text(encoding="utf-8"))
    metrics = metrics_path.read_text(encoding="utf-8")

    assert state["publication_complete"] is True
    assert state["consumer_convergence_ok"] is True
    assert state["consumer_restart_required"] is False
    assert [row["name"] for row in state["critical_consumers"]] == ["istiod", "istio-ingressgateway"]
    assert "threadforge_trust_consumer_convergence_ok 1.000000" in metrics
    assert "threadforge_trust_consumer_restart_required 0.000000" in metrics
    assert 'threadforge_trust_consumer_lineage_match{consumer="istio-ingressgateway"} 1.000000' in metrics


def test_export_state_flags_stale_consumer_restart_requirement(tmp_path: Path, monkeypatch) -> None:
    module = _load_module()
    active = _active_cert(module)
    aligned = {"name": "x", "present": True, "fingerprint_sha256": "active-fp", "fingerprint_sha3_256": "x", "serial": "fd487b", "not_before": "", "not_after": "", "ski": "", "aki": ""}
    source_rows = {
        "spire-ca-root-cert": dict(aligned, name="spire-ca-root-cert"),
        "istio-ca-root-cert": dict(aligned, name="istio-ca-root-cert"),
        "istiod-mounted-root": dict(aligned, name="istiod-mounted-root"),
        "workload-mounted-root": dict(aligned, name="workload-mounted-root"),
    }
    consumer_rows = {
        "istiod": {
            "name": "istiod",
            "namespace": "istio-system",
            "kind": "deployment",
            "remediation_target": "deployment/istiod",
            "pod": "istiod-abc",
            "source": "secret:istiod-tls",
            "present": True,
            "lineage_matches_active_root": True,
            "signer_chains_to_active_root": True,
            "leaf_chains_to_active_root": True,
            "root_matches_active_root": True,
            "restart_required": False,
            "error": "",
        },
        "istio-ingressgateway": {
            "name": "istio-ingressgateway",
            "namespace": "istio-system",
            "kind": "deployment",
            "remediation_target": "deployment/istio-ingressgateway",
            "pod": "gateway-abc",
            "source": "envoy-sds",
            "present": True,
            "lineage_matches_active_root": False,
            "signer_chains_to_active_root": False,
            "leaf_chains_to_active_root": False,
            "root_matches_active_root": True,
            "restart_required": True,
            "error": "",
        },
    }

    monkeypatch.setattr(module, "_utc_now", lambda: module.datetime(2026, 6, 6, 16, 0, 0, tzinfo=module.timezone.utc))
    monkeypatch.setattr(module, "_collect_active_root", lambda: (active, 4, 2))
    monkeypatch.setattr(module, "_collect_active_root_bundle", lambda: ("bundle-text", active, 4, 2))
    monkeypatch.setattr(module, "_safe_collect", lambda name, collector: dict(source_rows[name]))
    monkeypatch.setattr(module, "_safe_collect_consumer", lambda name, collector, active_cert: dict(consumer_rows[name]))

    state_path = tmp_path / "state.json"
    metrics_path = tmp_path / "metrics.prom"
    counters_path = tmp_path / "counters.json"
    counters_path.write_text("{}", encoding="utf-8")

    assert module.export_state(state_path, metrics_path, counters_path) == 0
    state = json.loads(state_path.read_text(encoding="utf-8"))
    metrics = metrics_path.read_text(encoding="utf-8")

    assert state["publication_complete"] is True
    assert state["consumer_convergence_ok"] is False
    assert state["consumer_restart_required"] is True
    stale = next(row for row in state["critical_consumers"] if row["name"] == "istio-ingressgateway")
    assert stale["restart_required"] is True
    assert 'threadforge_trust_consumer_restart_required{consumer="istio-ingressgateway"} 1.000000' in metrics


def test_no_istio_fallback_anchors_to_live_spire_bundle() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_no_istio_ca_fallback.sh").read_text()

    assert "select_active_spire_server_pod spire-system" in text
    assert 'exec -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -socketPath /run/spire/private/spire-server.sock -format pem' in text
    assert "get configmap spire-ca-root-cert" not in text
