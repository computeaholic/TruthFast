from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
PROMETHEUS_MANIFEST = REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "prometheus.yaml"
PROMETHEUS_RBAC = REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "prometheus-rbac.yaml"
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def _documents(path: Path) -> list[dict]:
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if isinstance(doc, dict)]


def _prometheus_config() -> dict:
    config_map = next(doc for doc in _documents(PROMETHEUS_MANIFEST) if doc.get("kind") == "ConfigMap")
    return yaml.safe_load(config_map["data"]["prometheus.yml"])


def test_control_plane_scrapes_use_authenticated_verified_https() -> None:
    jobs = {job["job_name"]: job for job in _prometheus_config()["scrape_configs"]}

    for job_name in ("kubernetes-apiservers", "kubernetes-nodes"):
        job = jobs[job_name]
        assert job["scheme"] == "https"
        assert job["authorization"] == {"credentials_file": TOKEN_FILE}
        assert job["tls_config"] == {"ca_file": CA_FILE}
        assert "insecure_skip_verify" not in job["tls_config"]

    api_relabels = jobs["kubernetes-apiservers"]["relabel_configs"]
    assert {"target_label": "__address__", "replacement": "kubernetes.default.svc:443"} in api_relabels


def test_prometheus_service_account_has_only_required_control_plane_access() -> None:
    role = next(doc for doc in _documents(PROMETHEUS_RBAC) if doc.get("kind") == "ClusterRole")
    non_resource_rules = [rule for rule in role["rules"] if "nonResourceURLs" in rule]
    resource_rules = [rule for rule in role["rules"] if "resources" in rule]

    assert non_resource_rules == [{"nonResourceURLs": ["/metrics"], "verbs": ["get"]}]
    assert any("nodes/proxy" in rule["resources"] and rule["verbs"] == ["get", "list", "watch"] for rule in resource_rules)


def test_control_plane_scrape_config_contains_no_embedded_credentials() -> None:
    text = PROMETHEUS_MANIFEST.read_text(encoding="utf-8")

    assert "bearer_token:" not in text
    assert "insecure_skip_verify: true" not in text
    assert text.count(TOKEN_FILE) == 2
    assert text.count(CA_FILE) == 2
