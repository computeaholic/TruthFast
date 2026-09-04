from __future__ import annotations

import json
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "platform" / "config" / "canonical_image_inventory.json"
INSTALL_ISTIO = ROOT / "scripts" / "install" / "install_istio.sh"
PREPARE_ISTIO = ROOT / "scripts" / "install" / "prepare_istio_images.sh"
PREPARE_AGENTS = ROOT / "scripts" / "install" / "prepare_agents_lab_images.sh"
SIGN_IMAGES = ROOT / "scripts" / "supply_chain" / "sign_images.sh"
VERIFY_RUNTIME_DIGEST_BINDING = ROOT / "scripts" / "verify" / "verify_runtime_digest_binding.sh"
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"
DEPLOY_LAB = ROOT / "scripts" / "install" / "deploy_lab.sh"


def _expected_proxyv2_digest() -> str:
    inventory = json.loads(INVENTORY.read_text())
    for entry in inventory:
        if entry.get("internal_reference") == "registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b":
            return entry["expected_digest"].removeprefix("sha256:")
    raise AssertionError("canonical proxyv2 inventory entry not found")


def test_istio_proxyv2_defaults_follow_canonical_inventory() -> None:
    expected = _expected_proxyv2_digest()
    install_text = INSTALL_ISTIO.read_text()
    prepare_text = PREPARE_ISTIO.read_text()
    bootstrap_text = BOOTSTRAP.read_text()

    assert f'ISTIO_PROXYV2_DIGEST="${{ISTIO_PROXYV2_DIGEST:-{expected}}}"' in install_text
    assert f'ISTIO_PROXYV2_DIGEST="${{ISTIO_PROXYV2_DIGEST:-{expected}}}"' in prepare_text
    assert f'ISTIO_PROXYV2_DIGEST="${{ISTIO_PROXYV2_DIGEST:-{expected}}}"' in bootstrap_text


def test_istio_gateway_install_contract_covers_ingress_and_egress_root_projection() -> None:
    install_text = INSTALL_ISTIO.read_text()

    assert "ensure_gateway_root_projection istio-ingressgateway" in install_text
    assert "ensure_gateway_root_projection istio-egressgateway" in install_text
    assert '"name":"istio-ca-root-cert"' in install_text
    assert '"mountPath":"/etc/certs"' in install_text
    assert "kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=120s" in install_text
    assert "kubectl rollout status deployment/istio-egressgateway -n istio-system --timeout=120s" in install_text


def test_lab_deploy_uses_canonical_agent_image_generator() -> None:
    deploy_text = DEPLOY_LAB.read_text()

    assert "bash \"${REPO_ROOT}/scripts/install/prepare_agents_lab_images.sh\"" in deploy_text
    assert "bash \"${REPO_ROOT}/scripts/prepare_agents_lab_images.sh\"" not in deploy_text


def test_prepare_agents_lab_images_resolves_repo_root_from_scripts_install() -> None:
    text = PREPARE_AGENTS.read_text()

    assert 'REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"' in text
    assert 'REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-${REPO_ROOT}/certs/threadforge-ingress-ca.crt}"' in text
    assert 'THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"' in text
    assert 'THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"' in text
    assert 'IMAGE_OS="${AGENTS_IMAGE_OS:-linux}"' in text
    assert 'IMAGE_ARCH="${AGENTS_IMAGE_ARCH:-arm64}"' in text
    assert 'REGISTRY_CERT_DIR="$(mktemp -d)"' in text
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"' in text
    assert '--creds "${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}"' in text
    assert '--override-os "${IMAGE_OS}"' in text
    assert '--override-arch "${IMAGE_ARCH}"' in text
    assert 'echo "[ADVISORY-FAIL] non-authoritative path"' not in text
    assert 'exit 2' in text


def test_agents_lab_render_uses_ephemeral_resolved_manifest() -> None:
    prepare_text = PREPARE_AGENTS.read_text()
    deploy_text = DEPLOY_LAB.read_text()

    assert 'AGENTS_RESOLVED_DEPLOYMENTS:-${K8S_DIR}/deployments.resolved.yaml' in prepare_text
    assert 'RESOLVED_DEPLOYMENTS="$(mktemp)"' in deploy_text
    assert 'kubectl apply -f "${RESOLVED_DEPLOYMENTS}"' in deploy_text


def test_lab_deploy_has_a_supported_local_registry_default() -> None:
    text = DEPLOY_LAB.read_text()

    assert 'THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"' in text


def test_lab_deploy_serializes_admission_sensitive_workload_rollouts() -> None:
    text = DEPLOY_LAB.read_text()

    assert 'for app in research-agent writer-agent attacker-agent rogue-agent; do' in text
    assert 'kubectl apply -f "${RESOLVED_DEPLOYMENTS}" -l "app=${app}"' in text
    assert 'kubectl rollout status "deployment/${app}" -n agents-lab --timeout=180s' in text


def test_lab_deploy_verifies_initial_admission_without_ceremonial_restart() -> None:
    text = DEPLOY_LAB.read_text()

    initial_ready = text.index('[STEP 8.1] Wait for workloads to be ready')
    sidecar_check = text.index('[STEP 8.2] Verify sidecar is present on every workload pod')
    identity_check = text.index('[STEP 8.3] Verify SPIFFE identity material is present')

    assert initial_ready < sidecar_check < identity_check
    assert 'kubectl rollout restart deployment/' not in text
    assert 'Restart workloads to ensure sidecar-injected identity' not in text
    assert 'kubectl get pod -n agents-lab "${POD_NAME}" -o jsonpath=' in text
    assert 'kubectl exec deploy/${APP} -n agents-lab -- printenv SPIFFE_ID' in text


def test_agent_deployments_expose_apply_selectors() -> None:
    text = (ROOT / "platform" / "labs" / "agent-containment" / "k8s" / "deployments.yaml").read_text()

    assert text.count("  labels:\n    app:") == 4


def test_sign_images_honors_runtime_architecture_projection() -> None:
    text = SIGN_IMAGES.read_text()

    assert 'SIGN_IMAGES_OS="${SIGN_IMAGES_OS:-linux}"' in text
    assert 'SIGN_IMAGES_ARCH="${SIGN_IMAGES_ARCH:-arm64}"' in text
    assert '--override-os "$SIGN_IMAGES_OS"' in text
    assert '--override-arch "$SIGN_IMAGES_ARCH"' in text


def test_runtime_digest_binding_uses_isolated_registry_cert_dir() -> None:
    text = VERIFY_RUNTIME_DIGEST_BINDING.read_text()

    assert 'registry_cert_dir="$(mktemp -d)"' in text
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$registry_cert_dir/ca.crt"' in text
    assert 'rm -rf "$registry_cert_dir"' in text
    assert 'python3 - "$expected_images" "$runtime_json" "$PIN_MAP_PATH" "$registry_cert_dir"' in text
    assert 'registry_ca_cert_path.parent' not in text
