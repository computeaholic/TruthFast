from __future__ import annotations

import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_dashboard_runtime_image_is_pinned_and_publishable() -> None:
    pin_map = json.loads((REPO_ROOT / "platform" / "config" / "image_pin_map.json").read_text())
    cluster_image_map = json.loads((REPO_ROOT / "platform" / "config" / "cluster_image_map.json").read_text())
    assert (
        cluster_image_map.get("registry.threadforge.local:30500/etcd@sha256:22f892d7672adc0b9c86df67792afdb8b2dc08880f49f669eaaa59c47d7908c2")
        == "registry.threadforge.local:30500/etcd@sha256:22f892d7672adc0b9c86df67792afdb8b2dc08880f49f669eaaa59c47d7908c2"
    )
    assert (
        pin_map.get("registry.threadforge.local:30500/threadforge-api:v20260223-0")
        == "registry.threadforge.local:30500/threadforge-api@sha256:eb55cee8e7baedb754731d405b302713225510bad398508c206c187c1c6fa0e9"
    )
    assert (
        cluster_image_map.get("registry.threadforge.local:30500/threadforge/dashboard@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f")
        == "registry.threadforge.local:30500/threadforge/dashboard@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
    )
    assert (
        cluster_image_map.get("registry.threadforge.local:30500/threadforge/gateway@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f")
        == "registry.threadforge.local:30500/threadforge/gateway@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
    )
    assert (
        cluster_image_map.get("registry.threadforge.local:30500/threadforge/router-go@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f")
        == "registry.threadforge.local:30500/threadforge/router-go@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
    )
    assert (
        cluster_image_map.get("registry.threadforge.local:30500/threadforge/worker@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f")
        == "registry.threadforge.local:30500/threadforge/worker@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
    )

    pin_script = (REPO_ROOT / "scripts" / "proof" / "pin_runtime_images.sh").read_text()
    assert "registry.threadforge.local:30500/threadforge/dashboard@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f" in pin_script
    assert "registry.threadforge.local:30500/threadforge/gateway@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f" in pin_script
    assert "registry.threadforge.local:30500/threadforge/router-go@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f" in pin_script
    assert "registry.threadforge.local:30500/threadforge/worker@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f" in pin_script
    assert 'REGISTRY_CERT_DIR="$(mktemp -d)"' in pin_script
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"' in pin_script
    assert 'PROBE_MOUNT_PATH="${REGISTRY_TRUST_PROBE_MOUNT_PATH:-/etc/registry-ca/threadforge-ingress-ca.crt}"' in pin_script
    assert 'kubectl exec -n "$PROBE_NAMESPACE" "$probe_pod" -c "$PROBE_CONTAINER" -- cat "$PROBE_MOUNT_PATH"' in pin_script
    assert '--src-creds "$REGISTRY_CREDS"' in pin_script
    assert '--src-cert-dir "$REGISTRY_CERT_DIR"' in pin_script
