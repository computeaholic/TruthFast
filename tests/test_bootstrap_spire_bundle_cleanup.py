from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def test_bootstrap_clears_stale_spire_bundle_before_helm_install() -> None:
    text = BOOTSTRAP.read_text()

    delete_line = "kubectl -n spire-system delete configmap spire-bundle --ignore-not-found >/dev/null 2>&1 || true"
    delete_deployment_line = "kubectl delete deployment spire-server -n spire-system --ignore-not-found >/dev/null 2>&1 || true"
    wait_delete_deployment_line = "kubectl wait --for=delete deployment/spire-server -n spire-system --timeout=120s >/dev/null 2>&1 || true"
    helm_line = 'helm upgrade --install spire platform/deploy/infra/spire -n spire-system -f platform/deploy/infra/spire/values.yaml --set spireAgent.enabled=false --atomic=false'

    assert delete_line in text
    assert delete_deployment_line in text
    assert wait_delete_deployment_line in text
    assert helm_line in text
    assert text.index(delete_line) < text.index(helm_line)
    assert text.index(helm_line) < text.index(delete_deployment_line)
    assert text.index(delete_deployment_line) < text.index(wait_delete_deployment_line)
