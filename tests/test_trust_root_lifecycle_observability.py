from __future__ import annotations

import json
import runpy
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_LIB = REPO_ROOT / "scripts" / "lib" / "proof_artifact_manifest.sh"
GUARD = runpy.run_path(str(REPO_ROOT / "scripts" / "trust" / "trust_root_lifecycle_guard.py"))
compute_state = GUARD["compute_state"]
write_prom_metrics = GUARD["write_prom_metrics"]
build_spire_native_lifecycle = GUARD["build_spire_native_lifecycle"]
apply_spire_native_decisions = GUARD["apply_spire_native_decisions"]


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _make_root(nb: datetime, na: datetime) -> dict:
    return {"not_before": _iso(nb), "not_after": _iso(na), "pem": "<fake>"}


def _make_root_with_serial(nb: datetime, na: datetime, serial: str, public_key_sha256: str = "") -> dict:
    return {
        "not_before": _iso(nb),
        "not_after": _iso(na),
        "serial": serial.lower(),
        "public_key_sha256": public_key_sha256,
        "pem": "<fake>",
    }


def _read_embedded_configmap_json(path: Path, key: str) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    marker = f"  {key}: |"
    try:
        start = lines.index(marker)
    except ValueError as exc:  # pragma: no cover - assertion makes failure explicit
        raise AssertionError(f"{key} not found in {path}") from exc

    payload: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("---") or (line and not line.startswith("    ")):
            break
        payload.append(line[4:] if line.startswith("    ") else "")
    return json.loads("\n".join(payload))


def _bash(command: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", command],
        cwd=cwd or REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_metrics_export_includes_canonical_continuity_metrics(tmp_path: Path) -> None:
    now = datetime.now(timezone.utc)
    roots = [_make_root(now - timedelta(days=1), now + timedelta(days=30))]
    status = compute_state(roots, now, warning_hours=24, critical_hours=6, emergency_hours=1)

    metrics_path = tmp_path / "root_lifecycle_metrics.prom"
    write_prom_metrics(metrics_path, status)
    metrics = metrics_path.read_text(encoding="utf-8")

    assert "threadforge_trust_successor_count 0" in metrics
    assert "threadforge_trust_continuity_ok 0" in metrics
    assert "threadforge_trust_coverage_gap_detected 1" in metrics
    assert "threadforge_trust_spire_lifecycle_ok 0" in metrics
    assert "threadforge_trust_continuous_successor_policy_ok 0" in metrics


def _apply_spire_native_status(
    roots: list[dict],
    authority_payload: dict,
    key_fingerprints: set[str],
    now: datetime,
) -> dict:
    status = compute_state(roots, now, warning_hours=24, critical_hours=6, emergency_hours=1)
    spire_native = build_spire_native_lifecycle(roots, authority_payload, key_fingerprints, now=now)
    return apply_spire_native_decisions(status, spire_native)


def test_spire_native_lifecycle_decision_replaces_legacy_successor_model() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_nb = datetime(2026, 6, 5, 14, 20, 29, tzinfo=timezone.utc)
    active_na = datetime(2026, 6, 6, 14, 20, 39, tzinfo=timezone.utc)
    prepared_nb = datetime(2026, 6, 6, 2, 20, 29, tzinfo=timezone.utc)
    prepared_na = datetime(2026, 6, 7, 2, 20, 39, tzinfo=timezone.utc)
    roots = [
        _make_root_with_serial(active_nb, active_na, "b2a3", "active-key"),
        _make_root_with_serial(prepared_nb, prepared_na, "fd48", "prepared-key"),
    ]
    status = _apply_spire_native_status(
        roots,
        {
            "source": "unit-test",
            "active": {"state": "ACTIVE", "serial": "b2a3", "not_after": _iso(active_na)},
            "prepared": {
                "state": "PREPARED",
                "serial": "fd48",
                "not_before": _iso(prepared_nb),
                "not_after": _iso(prepared_na),
            },
            "old": [{"state": "OLD", "serial": "old1"}],
        },
        {"prepared-key"},
        now,
    )

    assert status["legacy_bundle_successor_model"] == {
        "successor_count": 0,
        "continuity_ok": False,
        "coverage_gap_detected": True,
        "future_root_count": 0,
    }
    assert status["active_root_serial"] == "b2a3"
    assert status["spire_lifecycle_ok"] is True
    assert status["continuous_successor_policy_ok"] is True
    assert status["prepare_due"] is True
    assert status["activate_due"] is False
    assert status["continuity_state"] == "ACTIVE_PLUS_PREPARED"
    assert status["successor_count"] == 1
    assert status["continuity_ok"] is True
    assert status["coverage_gap_detected"] is False
    spire_native = status["spire_native_lifecycle"]
    assert spire_native["active_authority_state"][0]["serial"] == "b2a3"
    assert spire_native["prepared_authority_state"][0]["serial"] == "fd48"
    assert spire_native["old_authority_state"][0]["serial"] == "old1"
    assert spire_native["prepared_published"] is True
    assert spire_native["prepared_key_present"] is True
    assert spire_native["overlap_duration_hours"] == 12.003
    assert spire_native["extends_active"] is True


def test_spire_lifecycle_stays_healthy_when_prepare_not_due_and_prepared_missing() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = now + timedelta(hours=10)
    roots = [_make_root_with_serial(now - timedelta(hours=1), active_na, "active", "active-key")]
    status = _apply_spire_native_status(
        roots,
        {"source": "unit-test", "active": {"state": "ACTIVE", "serial": "active", "not_after": _iso(active_na)}},
        {"active-key"},
        now,
    )

    assert status["successor_count"] == 0
    assert status["spire_lifecycle_ok"] is True
    assert status["continuous_successor_policy_ok"] is False
    assert status["prepare_due"] is False
    assert status["continuity_state"] == "ACTIVE_ONLY"
    assert status["continuity_ok"] is False
    assert status["coverage_gap_detected"] is True
    assert status["spire_native_continuity_predicates"]["prepared_exists"] is False


def test_spire_lifecycle_fails_closed_when_prepare_due_and_prepared_missing() -> None:
    now = datetime(2026, 6, 6, 9, 9, 8, tzinfo=timezone.utc)
    active_nb = now - timedelta(hours=8)
    active_na = now + timedelta(hours=4)
    roots = [_make_root_with_serial(active_nb, active_na, "active", "active-key")]
    status = _apply_spire_native_status(
        roots,
        {"source": "unit-test", "active": {"state": "ACTIVE", "serial": "active", "not_before": _iso(active_nb), "not_after": _iso(active_na)}},
        {"active-key"},
        now,
    )

    assert status["spire_lifecycle_ok"] is False
    assert status["continuous_successor_policy_ok"] is False
    assert status["prepare_due"] is True
    assert status["continuity_state"] == "PREPARE_DUE"


def test_spire_native_continuity_fails_closed_when_prepared_not_published() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = now + timedelta(hours=10)
    prepared_nb = now - timedelta(minutes=10)
    prepared_na = active_na + timedelta(hours=10)
    roots = [_make_root_with_serial(now - timedelta(hours=1), active_na, "active", "active-key")]
    status = _apply_spire_native_status(
        roots,
        {
            "source": "unit-test",
            "active": {"state": "ACTIVE", "serial": "active", "not_after": _iso(active_na)},
            "prepared": {
                "state": "PREPARED",
                "serial": "missing",
                "not_before": _iso(prepared_nb),
                "not_after": _iso(prepared_na),
                "key_present": True,
            },
        },
        {"active-key"},
        now,
    )

    assert status["continuity_ok"] is False
    assert status["coverage_gap_detected"] is True
    assert status["spire_lifecycle_ok"] is True
    assert status["spire_native_continuity_predicates"]["prepared_published"] is False


def test_spire_native_continuity_fails_closed_when_prepared_key_missing() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = now + timedelta(hours=10)
    prepared_nb = now - timedelta(minutes=10)
    prepared_na = active_na + timedelta(hours=10)
    roots = [
        _make_root_with_serial(now - timedelta(hours=1), active_na, "active", "active-key"),
        _make_root_with_serial(prepared_nb, prepared_na, "prepared", "prepared-key"),
    ]
    status = _apply_spire_native_status(
        roots,
        {
            "source": "unit-test",
            "active": {"state": "ACTIVE", "serial": "active", "not_after": _iso(active_na)},
            "prepared": {"state": "PREPARED", "serial": "prepared", "not_before": _iso(prepared_nb), "not_after": _iso(prepared_na)},
        },
        set(),
        now,
    )

    assert status["continuity_ok"] is False
    assert status["coverage_gap_detected"] is True
    assert status["spire_lifecycle_ok"] is True
    assert status["spire_native_continuity_predicates"]["prepared_key_present"] is False


def test_spire_native_continuity_fails_closed_without_overlap() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = now + timedelta(hours=10)
    prepared_nb = active_na + timedelta(seconds=1)
    prepared_na = active_na + timedelta(hours=10)
    roots = [
        _make_root_with_serial(now - timedelta(hours=1), active_na, "active", "active-key"),
        _make_root_with_serial(prepared_nb, prepared_na, "prepared", "prepared-key"),
    ]
    status = _apply_spire_native_status(
        roots,
        {
            "source": "unit-test",
            "active": {"state": "ACTIVE", "serial": "active", "not_after": _iso(active_na)},
            "prepared": {"state": "PREPARED", "serial": "prepared", "not_before": _iso(prepared_nb), "not_after": _iso(prepared_na)},
        },
        {"prepared-key"},
        now,
    )

    assert status["continuity_ok"] is False
    assert status["coverage_gap_detected"] is True
    assert status["spire_lifecycle_ok"] is True
    assert status["spire_native_continuity_predicates"]["overlap_exists"] is False


def test_spire_native_continuity_fails_closed_when_prepared_does_not_extend_active() -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = now + timedelta(hours=10)
    prepared_nb = now - timedelta(minutes=10)
    prepared_na = active_na
    roots = [
        _make_root_with_serial(now - timedelta(hours=1), active_na, "active", "active-key"),
        _make_root_with_serial(prepared_nb, prepared_na, "prepared", "prepared-key"),
    ]
    status = _apply_spire_native_status(
        roots,
        {
            "source": "unit-test",
            "active": {"state": "ACTIVE", "serial": "active", "not_after": _iso(active_na)},
            "prepared": {"state": "PREPARED", "serial": "prepared", "not_before": _iso(prepared_nb), "not_after": _iso(prepared_na)},
        },
        {"prepared-key"},
        now,
    )

    assert status["continuity_ok"] is False
    assert status["coverage_gap_detected"] is True
    assert status["spire_lifecycle_ok"] is True
    assert status["spire_native_continuity_predicates"]["extends_active"] is False


def test_spire_native_metrics_are_exported_without_legacy_decision_change(tmp_path: Path) -> None:
    now = datetime(2026, 6, 6, 3, 9, 8, tzinfo=timezone.utc)
    active_na = datetime(2026, 6, 6, 14, 20, 39, tzinfo=timezone.utc)
    prepared_nb = datetime(2026, 6, 6, 2, 20, 29, tzinfo=timezone.utc)
    roots = [_make_root_with_serial(now - timedelta(hours=1), active_na, "a")]
    status = compute_state(roots, now, warning_hours=24, critical_hours=6, emergency_hours=1)
    status["spire_native_lifecycle"] = {
        "active_authority_state": [{"serial": "a"}],
        "prepared_authority_state": [{"serial": "b"}],
        "old_authority_state": [{"serial": "old"}],
        "prepared_published": True,
        "prepared_key_present": False,
        "overlap_duration_hours": round((active_na - prepared_nb).total_seconds() / 3600.0, 3),
        "extends_active": True,
    }

    metrics_path = tmp_path / "root_lifecycle_metrics.prom"
    write_prom_metrics(metrics_path, status)
    metrics = metrics_path.read_text(encoding="utf-8")

    assert "threadforge_trust_successor_count 0" in metrics
    assert "threadforge_trust_continuity_ok 0" in metrics
    assert "threadforge_trust_coverage_gap_detected 1" in metrics
    assert "threadforge_trust_spire_lifecycle_ok 0" in metrics
    assert "threadforge_trust_continuous_successor_policy_ok" in metrics
    assert "threadforge_trust_prepare_due" in metrics
    assert "threadforge_trust_activate_due" in metrics
    assert "threadforge_trust_spire_active_authority_present 1" in metrics
    assert "threadforge_trust_spire_prepared_authority_present 1" in metrics
    assert "threadforge_trust_spire_old_authority_count 1" in metrics
    assert "threadforge_trust_spire_prepared_published 1" in metrics
    assert "threadforge_trust_spire_prepared_key_present 0" in metrics
    assert "threadforge_trust_spire_prepared_overlap_duration_hours 12.003" in metrics
    assert "threadforge_trust_spire_prepared_extends_active 1" in metrics


def test_prometheus_rules_use_canonical_lifecycle_metrics() -> None:
    text = (REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "prometheus.yaml").read_text(
        encoding="utf-8"
    )

    assert "trust-root-lifecycle.rules.yaml" in text
    assert "record: threadforge_trust_continuity_state_code" in text
    assert "record: threadforge_trust_prepare_window_missing_successor" in text
    assert "alert: TrustRootPrepareWindowMissingSuccessor" in text
    assert "expr: threadforge_trust_prepare_window_missing_successor == 1" in text
    assert "alert: TrustRootContinuityLost" in text
    assert "expr: threadforge_trust_spire_lifecycle_ok == 0" in text
    assert "threadforge_trust_prepare_due == bool 1" in text
    assert "threadforge_trust_successor_count < bool 1" in text
    assert "threadforge_trust_continuous_successor_policy_ok" in text
    assert "threadforge_trust_coverage_gap_detected" in text


def test_prometheus_statefulset_memory_budget_allows_wal_replay() -> None:
    text = (REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "prometheus.yaml").read_text(
        encoding="utf-8"
    )

    assert "memory: 512Mi" in text
    assert "memory: 1Gi" in text


def test_dashboard_contains_continuity_panels_and_queries() -> None:
    dashboard = _read_embedded_configmap_json(
        REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "grafana.yaml",
        "trust-root-lifecycle.json",
    )
    titles = {panel.get("title") for panel in dashboard.get("panels", [])}
    assert {
        "Continuity State",
        "Prepare Due",
        "Activate Due",
        "Active Root Present",
        "Prepared Root Present",
        "Prepared Published",
        "Prepared Key Present",
        "Successor Count",
        "Valid Root Count",
        "Continuous Successor Policy",
        "Coverage Gap",
        "Prepare Window Missing Successor",
        "SPIRE Lifecycle OK",
    } <= titles

    dashboard_text = json.dumps(dashboard, sort_keys=True)
    assert "threadforge_trust_continuity_state_code" in dashboard_text
    assert "threadforge_trust_prepare_window_missing_successor" in dashboard_text
    assert "threadforge_trust_prepare_due" in dashboard_text
    assert "threadforge_trust_activate_due" in dashboard_text
    assert "threadforge_trust_spire_active_authority_present" in dashboard_text
    assert "threadforge_trust_spire_prepared_authority_present" in dashboard_text
    assert "threadforge_trust_spire_prepared_published" in dashboard_text
    assert "threadforge_trust_spire_prepared_key_present" in dashboard_text
    assert "threadforge_trust_successor_count" in dashboard_text
    assert "threadforge_trust_valid_root_count" in dashboard_text
    assert "threadforge_trust_continuous_successor_policy_ok" in dashboard_text
    assert "threadforge_trust_coverage_gap_detected" in dashboard_text
    assert "threadforge_trust_spire_lifecycle_ok" in dashboard_text
    assert "ACTIVE_ONLY" in dashboard_text
    assert "PREPARE_DUE" in dashboard_text
    assert "ROTATING" in dashboard_text


def test_proof_artifact_manifest_includes_root_lifecycle_status_when_present(tmp_path: Path) -> None:
    proof_dir = tmp_path / "proof"
    proof_dir.mkdir()
    (proof_dir / "root_lifecycle_status.json").write_text("{}\n", encoding="utf-8")

    result = _bash(f'source "{MANIFEST_LIB}" && proof_latest_artifact_names "{proof_dir}"')

    assert result.returncode == 0, result.stderr
    assert "root_lifecycle_status.json" in result.stdout.strip().splitlines()


def test_proof_pipeline_surfaces_root_lifecycle_fields() -> None:
    prove_text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text(encoding="utf-8")
    verify_text = (REPO_ROOT / "scripts" / "verify" / "verify_root_lifecycle_continuity.sh").read_text(encoding="utf-8")
    proof_verifier_text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text(encoding="utf-8")

    assert 'cp "$REPO_ROOT/artifacts/trust/root_lifecycle_status.json" "$LOG_DIR/root_lifecycle_status.json"' in prove_text
    assert '"root_lifecycle_status.json"' in prove_text
    assert "successor_count=$successor_count" in verify_text
    assert "spire_lifecycle_ok=$spire_lifecycle_ok" in verify_text
    assert "continuous_successor_policy_ok=$continuous_successor_policy_ok" in verify_text
    assert "prepare_due=$prepare_due" in verify_text
    assert "continuity_ok=$continuity_ok" in verify_text
    assert "coverage_gap_detected=$coverage_gap" in verify_text
    assert 'if [[ "$prepare_due" == "true" ]]; then' in verify_text
    assert 'if root_lifecycle.get("prepare_due") is True:' in proof_verifier_text
    assert 'missing successor_root_validation.json when prepare_due is true' in proof_verifier_text


def test_spire_lifecycle_evidence_generator_is_observe_only() -> None:
    text = (REPO_ROOT / "scripts" / "trust" / "generate_spire_lifecycle_evidence.sh").read_text(encoding="utf-8")

    assert "bundle show" in text
    assert "trust_root_lifecycle_guard.py" in text
    assert "mutation_performed: false" in text
    assert "PrepareX509Authority" not in text
    assert "ActivateX509Authority" not in text
    assert "bundle set" not in text


def test_trust_refresh_recreates_stale_reader_with_bounded_readiness() -> None:
    bootstrap_text = (REPO_ROOT / "scripts" / "infra" / "bootstrap.sh").read_text(encoding="utf-8")
    refresh_text = (REPO_ROOT / "scripts" / "verify" / "refresh_spire_istio_ca_path.sh").read_text(encoding="utf-8")
    text = (REPO_ROOT / "scripts" / "verify" / "verify_root_lifecycle_continuity.sh").read_text(encoding="utf-8")
    assert 'bash "$REPO_ROOT/scripts/infra/ensure_spire_root_key_reader.sh"' in bootstrap_text
    assert 'SPIRE_SERVER_SOCKET_PATH' in bootstrap_text
    reader_text = (REPO_ROOT / "scripts" / "infra" / "ensure_spire_root_key_reader.sh").read_text(encoding="utf-8")
    assert 'bash "$REPO_ROOT/scripts/infra/ensure_spire_root_key_reader.sh"' in refresh_text
    assert 'kubectl delete pod "$POD_NAME" -n spire-system --wait=true' in reader_text
    assert 'spire_server_data_volume=' in reader_text
    assert '--argjson data_volume "$spire_server_data_volume"' in reader_text
    assert 'nodeName: $node' in reader_text
    assert 'claimName: spire-server-data' not in reader_text
    assert 'kubectl wait -n spire-system --for=condition=Ready "pod/${POD_NAME}"' in reader_text
    assert "bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469" in reader_text
    assert "REGISTRY_HOSTPORT" in reader_text
    assert "spire-root-key-reader" in refresh_text
    assert 'json_configmap_field observability istio-ca-root-cert' in refresh_text
    assert "select_active_spire_server_pod" in text
    assert 'SPIRE_SOCKET="${SPIRE_SOCKET:-/run/spire/private/spire-server.sock}"' in text
    assert "kubectl apply -f -" not in text
    assert "kubectl wait -n \"$SPIRE_NAMESPACE\" --for=condition=Ready pod/\"$SPIRE_KEYS_READER_POD\"" not in text
    assert "kubectl exec -n \"$SPIRE_NAMESPACE\" \"$SPIRE_KEYS_READER_POD\" -c reader -- cat /run/spire/data/keys.json" not in text
    assert "SPIRE_KEYS_READER_POD" not in text


def test_spire_server_has_one_chart_owned_data_claim() -> None:
    statefulset_text = (
        REPO_ROOT / "platform" / "deploy" / "infra" / "spire" / "templates" / "spire-server-statefulset.yaml"
    ).read_text(encoding="utf-8")
    pvc_text = (
        REPO_ROOT / "platform" / "deploy" / "infra" / "spire" / "templates" / "spire-server-pvc.yaml"
    ).read_text(encoding="utf-8")

    assert "volumeClaimTemplates:" not in statefulset_text
    assert "claimName: spire-server-data" in statefulset_text
    assert "name: spire-server-data" in pvc_text


def test_observability_inventory_maps_trust_root_lifecycle() -> None:
    canonical_text = (REPO_ROOT / "docs" / "CANONICAL" / "OBSERVABILITY.md").read_text(encoding="utf-8")
    obs_text = (REPO_ROOT / "docs" / "operations" / "OBSERVABILITY.md").read_text(encoding="utf-8")

    assert "Observability is a proof prerequisite" in canonical_text
    assert "trust-root-lifecycle" in obs_text
    assert "Continuity State" in obs_text
    assert "ACTIVE_ONLY" in obs_text
    assert "PREPARE_DUE" in obs_text
    assert "threadforge_trust_continuity_state_code" in obs_text
    assert "threadforge_trust_prepare_window_missing_successor" in obs_text
    assert "TrustRootPrepareWindowMissingSuccessor" in obs_text
    assert "TrustRootContinuityLost" in obs_text
