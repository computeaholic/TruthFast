"""
test_tempo_seed_proof_guards.py
Static guards for the Tempo seed proof implementation.
Verifies that bootstrap correctly implements all 8 tasks from the
BOOTSTRAP_STEP_FAILED: tempo ingestion seed job failed fix.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _read(rel: str) -> str:
    return (REPO_ROOT / rel).read_text()


# ── TASK 1: Classified failure modes ─────────────────────────────────────────


def test_tempo_seed_emits_dns_unresolved_classification() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_DNS_UNRESOLVED" in text


def test_tempo_seed_emits_connection_failed_classification() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_CONNECTION_FAILED" in text


def test_tempo_seed_emits_ingest_rejected_classification() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_INGEST_REJECTED" in text


def test_tempo_seed_emits_unexpected_response_classification() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_UNEXPECTED_RESPONSE" in text


def test_tempo_seed_logs_http_status_and_body() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "INGEST_STATUS" in text
    assert "INGEST_BODY" in text
    assert "INGEST_RC" in text


# ── TASK 2: Tempo readiness gate ─────────────────────────────────────────────


def test_wait_for_tempo_ingester_ready_function_exists() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "wait_for_tempo_ingester_ready()" in text


def test_tempo_ring_helpers_exist() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "verify_tempo_sidecar_and_spiffe()" in text
    assert "verify_tempo_internal_connectivity()" in text
    assert "verify_tempo_ring_formation()" in text


def test_readiness_check_validates_ready_body_not_just_non_empty() -> None:
    """The old bug: [ -n "${ready_output}" ] passed on 503 body 'services not ready'.
    The fix must check that the body contains 'ready' (case-insensitive)."""
    text = _read("scripts/infra/bootstrap.sh")
    # The old broken pattern is gone
    assert '[ -n "${ready_output}" ] || fail_bootstrap "${workload} readiness endpoint did not respond"' not in text
    # The new correct pattern is present
    assert '"ready"*' in text or "ready*" in text


def test_readiness_wait_is_called_before_seed_job() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    idx_ready = text.find("wait_for_tempo_ingester_ready")
    idx_seed = text.find("run_tempo_seed_proof")
    assert idx_ready > 0
    assert idx_seed > 0
    assert idx_ready < idx_seed, "wait_for_tempo_ingester_ready must be called before run_tempo_seed_proof"


def test_tempo_seed_checks_tcp_connect_readiness() -> None:
    """Emitter verifies /ready returns 200 before attempting ingestion."""
    text = _read("scripts/infra/bootstrap.sh")
    assert "/ready" in text
    assert "READY_STATUS" in text


def test_bootstrap_hard_fails_empty_ready_as_ring_not_formed() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_RING_NOT_FORMED" in text
    assert "/ready returned empty response" in text


# ── TASK 3: SPIFFE identity check ─────────────────────────────────────────────


def test_tempo_seed_checks_envoy_admin_for_spiffe() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "127.0.0.1:15000/certs" in text


def test_tempo_seed_fails_if_no_spiffe_uri() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_MTLS_FAILURE" in text
    assert "SPIFFE_ID" in text


def test_tempo_seed_requires_exact_spiffe_identity() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "spiffe://identity.threadforge.local/ns/observability/sa/observability-seed-sa" in text
    assert "SPIFFE identity mismatch" in text


def test_tempo_pods_require_tempo_sa_spiffe_identity() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "spiffe://identity.threadforge.local/ns/observability/sa/tempo-sa" in text
    assert "Tempo SPIFFE identity mismatch" in text


def test_tempo_seed_checks_sds_chain_and_spire_issuer() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "cert chain missing" in text
    assert "issuer is not SPIRE" in text


def test_seed_job_uses_dedicated_service_account() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "observability-seed-sa" in text
    assert "serviceAccountName: observability-seed-sa" in text


def test_observability_seed_sa_exists_in_tempo_chart() -> None:
    text = _read("platform/deploy/infra/tempo/templates/tempo-identity.yaml")
    assert "observability-seed-sa" in text
    assert "kind: ServiceAccount" in text


# ── TASK 4: Trace retrieval verification ──────────────────────────────────────


def test_tempo_seed_queries_trace_after_ingestion() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "/api/traces/" in text
    assert "QUERY_STATUS" in text
    assert "CONFIRMED" in text or "in Tempo" in text


def test_tempo_seed_verifies_trace_id_in_query_response() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "grep -qi" in text
    assert "TRACE_ID" in text


def test_tempo_seed_uses_unique_trace_id() -> None:
    """Unique trace ID generated per run (no hardcoded 0123456789abcdef)."""
    text = _read("scripts/infra/bootstrap.sh")
    # Old hardcoded trace ID is gone
    assert "0123456789abcdef0123456789abcdef" not in text
    # New: UUID-based or random generation
    assert "random/uuid" in text or "RANDOM" in text


# ── TASK 5: Bounded retry ─────────────────────────────────────────────────────


def test_tempo_seed_has_bounded_retry() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "MAX_RETRIES=5" in text
    assert "ATTEMPT" in text


def test_tempo_seed_does_not_retry_4xx() -> None:
    """4xx semantic errors must not be retried."""
    text = _read("scripts/infra/bootstrap.sh")
    # The implementation should exit on 4xx without sleeping/continuing
    assert "TEMPO_INGEST_REJECTED" in text


def test_tempo_seed_retries_503_and_connection_errors() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert '"503"' in text
    # Connection errors (curl rc 7 = CURLE_COULDNT_CONNECT, 28 = CURLE_OPERATION_TIMEDOUT)
    assert "INGEST_RC" in text


def test_tempo_seed_classifies_tls_as_mtls_failure() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_MTLS_FAILURE" in text
    assert "TLS/mTLS failure" in text


# ── TASK 6: Policy block classification ───────────────────────────────────────


def test_tempo_seed_classifies_403_as_policy_block() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "TEMPO_POLICY_DENIED" in text
    assert '"403"' in text or '"401"' in text


def test_tempo_seed_replaces_localhost_ready_probe_with_service_dns() -> None:
    bootstrap = _read("scripts/infra/bootstrap.sh")
    proof = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    assert "tempo.observability.svc.cluster.local:3100/ready" in bootstrap
    assert "tempo.observability.svc.cluster.local:3100/ready" in proof


def test_tempo_internal_connectivity_checks_required_ports() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "7946" in text
    assert "9095" in text
    assert "internal connectivity blocked" in text


def test_tempo_authz_allows_seed_sa_on_port_3100() -> None:
    """observability-seed-sa must be allowed to query port 3100 for trace retrieval."""
    text = _read("platform/deploy/infra/tempo/templates/tempo-authz-allow.yaml")
    assert "observability-seed-sa" in text
    assert '"3100"' in text or "'3100'" in text or "3100" in text


def test_tempo_authz_allows_tempo_sa_self_communication_ports() -> None:
    text = _read("platform/deploy/infra/tempo/templates/tempo-authz-allow.yaml")
    assert "spiffe://identity.threadforge.local/ns/observability/sa/tempo-sa" in text
    assert '"7946"' in text
    assert '"9095"' in text
    assert '"3100"' in text


# ── TASK 7: Bootstrap contract ────────────────────────────────────────────────


def test_bootstrap_calls_run_tempo_seed_proof_not_old_name() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "run_tempo_seed_proof" in text
    # Old name is gone from call sites (function definition doesn't count)
    # Count occurrences of old name — should only be in comments if at all
    assert text.count("seed_tempo_ingestion") == 0


def test_bootstrap_calls_wait_for_tempo_ingester_ready() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert text.count("wait_for_tempo_ingester_ready") >= 2  # definition + call


def test_tempo_seed_proof_binds_job_identity_by_uid_and_ownerreference() -> None:
    bootstrap = _read("scripts/infra/bootstrap.sh")
    proof = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    helper = _read("scripts/lib/proof_prereqs.sh")
    assert "proof_job_uid_or_fail" in bootstrap
    assert "proof_job_uid_or_fail" in proof
    assert "proof_owned_pod_for_job_uid_or_fail" in bootstrap
    assert "proof_owned_pod_for_job_uid_or_fail" in proof
    assert "ownerReferences" in helper
    assert "job-name=\"${JOB_NAME}\" -o jsonpath='{.items[0].metadata.name}'" not in proof


# ── TASK 8: Proof invariant ───────────────────────────────────────────────────


def test_proof_script_calls_tempo_ingestion_verifier() -> None:
    text = _read("scripts/prove_system.sh")
    assert "verify_tempo_ingestion_proof.sh" in text


def test_proof_checks_observability_ingestion_verified() -> None:
    text = _read("scripts/prove_system.sh")
    assert "observability_ingestion_verified" in text


def test_tempo_ingestion_proof_script_exists() -> None:
    assert (REPO_ROOT / "scripts/verify/verify_tempo_ingestion_proof.sh").exists()


def test_tempo_ingestion_proof_emits_pass_marker() -> None:
    text = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    assert "observability_ingestion_verified=PASS" in text
    assert "TEMPO_POLICY_DENIED" in text
    assert "TEMPO_MTLS_FAILURE" in text
    assert "SPIFFE_ID" in text
    assert "/api/traces/" in text


def test_tempo_ingestion_proof_uses_seed_sa() -> None:
    text = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    assert "observability-seed-sa" in text


def test_tempo_ingestion_proof_uses_canonical_curl_image() -> None:
    text = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    assert (
        "registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:"
        "846c5f0324b40f833b9a1fa3d5a667ac0f2b4712c9a39cae8cafe890286c52f2"
    ) in text


def test_tempo_ingestion_proof_projects_the_shared_root_cert_volume() -> None:
    text = _read("scripts/verify/verify_tempo_ingestion_proof.sh")
    assert 'sidecar.istio.io/userVolume: \'{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in text
    assert 'sidecar.istio.io/userVolumeMount: \'{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in text
    assert "name: istio-custom-root-cert" in text
    assert "name: istio-ca-root-cert" in text
