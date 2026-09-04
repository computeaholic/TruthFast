"""Tests for AuthorizationPolicy normalization and single enforcement boundary.

Proves that:
1. No duplicate AuthZ policies exist for the same workload
2. Selector matches actual deployment labels
3. Single enforcement boundary is provable
"""

import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml
from tests.threadforge_test_mode import get_test_mode, skip_in_local_mode

pytestmark = pytest.mark.integration
REPO_ROOT = Path(__file__).resolve().parents[2]


def test_no_duplicate_authz_policies_via_helm():
    """Verify no duplicate AuthorizationPolicy resources via helm template."""
    result = subprocess.run(
        ["helm", "template", "platform/deploy/infra/istio", "--set", "global.authz.enabled=true"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if result.returncode != 0:
        skip_in_local_mode(
            f"Helm template failed: {result.stderr}",
            failure_reason=f"Helm template failed in {get_test_mode()} mode: {result.stderr}",
        )

    docs = list(yaml.safe_load_all(result.stdout))
    authz_policies = [doc for doc in docs if doc and doc.get("kind") == "AuthorizationPolicy"]

    selector_groups: dict[str, list[str]] = {}
    for policy in authz_policies:
        spec = policy.get("spec", {})
        selector = spec.get("selector", {})
        match_labels = selector.get("matchLabels", {})
        app_label = match_labels.get("app")

        if app_label:
            if app_label not in selector_groups:
                selector_groups[app_label] = []
            selector_groups[app_label].append(policy["metadata"]["name"])

    duplicates = {app: names for app, names in selector_groups.items() if len(names) > 1}
    assert not duplicates, f"Duplicate AuthZ policies found: {duplicates}"


def test_api_authz_selector_matches_deployment():
    """Verify API AuthorizationPolicy selector matches actual deployment label."""
    deploy_result = subprocess.run(
        [
            "helm",
            "template",
            "platform/deploy/services/api",
            "--set",
            "image.repository=test",
            "--set",
            "image.tag=test",
        ],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if deploy_result.returncode != 0:
        skip_in_local_mode(
            f"Helm template for deployment failed: {deploy_result.stderr}",
            failure_reason=(f"Helm template for deployment failed in {get_test_mode()} mode: {deploy_result.stderr}"),
        )

    deploy_docs = list(yaml.safe_load_all(deploy_result.stdout))
    deployment = next((doc for doc in deploy_docs if doc and doc.get("kind") == "Deployment"), None)

    assert deployment is not None, "Deployment not found in helm output"
    deployment_label = deployment["spec"]["selector"]["matchLabels"]["app"]

    authz_result = subprocess.run(
        ["helm", "template", "platform/deploy/infra/istio", "--set", "global.authz.enabled=true"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if authz_result.returncode != 0:
        skip_in_local_mode(
            f"Helm template for authz failed: {authz_result.stderr}",
            failure_reason=(f"Helm template for authz failed in {get_test_mode()} mode: {authz_result.stderr}"),
        )

    authz_docs = list(yaml.safe_load_all(authz_result.stdout))
    api_authz = next(
        (
            doc
            for doc in authz_docs
            if doc and doc.get("kind") == "AuthorizationPolicy" and "api" in doc["metadata"]["name"]
        ),
        None,
    )

    assert api_authz is not None, "API AuthorizationPolicy not found"
    authz_selector = api_authz["spec"]["selector"]["matchLabels"]["app"]

    assert (
        authz_selector == deployment_label
    ), f"Selector mismatch: AuthZ uses '{authz_selector}' but Deployment uses '{deployment_label}'"


def test_unauthenticated_envelope_rejected():
    """Prove a request without proxy-authenticated identity fails at the canonical API boundary."""
    from fastapi.testclient import TestClient

    from runtime.api.app import app

    client = TestClient(app)
    response = client.post("/vector/embed", json={"text": "test"})

    assert response.status_code == 401


def test_authenticated_envelope_reaches_router(monkeypatch):
    """Prove a valid proxy-bound SPIFFE identity can reach the canonical router."""
    from fastapi.testclient import TestClient

    import runtime.api.router_api as router_api
    from runtime.api.app import app

    monkeypatch.setattr(
        router_api,
        "operator_core",
        lambda: SimpleNamespace(execute=lambda envelope: {"ok": True, "envelope_id": envelope.envelope_id}),
    )

    client = TestClient(app)
    response = client.post(
        "/vector/embed",
        json={"text": "test"},
        headers={
            "x-forwarded-client-cert": (
                "By=spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway;"
                "URI=spiffe://identity.threadforge.local/ns/threadforge/sa/operator-ai;Hash=abc123"
            )
        },
    )

    assert response.status_code == 200
    assert response.json()["ok"] is True
