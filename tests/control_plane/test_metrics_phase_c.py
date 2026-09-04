"""Phase C metrics exposure tests.

Verifies that identity capability cache metrics are exposed via the shared
/metrics endpoint (Prometheus-compatible) used by the API server.
"""

from fastapi.testclient import TestClient

from runtime.api.app import app


def test_metrics_endpoint_exposes_identity_cache_metrics():
    client = TestClient(app)

    resp = client.get("/metrics")
    assert resp.status_code == 200
    body = resp.text

    # Identity capability cache metrics should be present even at zero values.
    assert "tf_identity_capability_cache_hits_total" in body
    assert "tf_identity_capability_cache_misses_total" in body
    assert "tf_identity_capability_cache_invalidations_total" in body
    assert "tf_identity_capability_cache_size" in body

    # Content type should be Prometheus exposition format
    assert resp.headers.get("content-type", "").startswith("text/plain")
