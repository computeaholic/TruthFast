from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RECONCILER = REPO_ROOT / "scripts" / "proof" / "reconcile_spire_entries.sh"


def test_trust_domain_resolution_uses_live_entries_before_server_config() -> None:
    text = RECONCILER.read_text(encoding="utf-8")

    live_index = text.index(
        "entries_json=\"$(run_spire_server_with_fallback entry show"
    )
    config_index = text.index(
        "config_text=\"$(run_kubectl get configmap spire-server-config"
    )
    assert live_index < config_index
    assert "resolve_live_spire_trust_domain" in text


def test_cold_start_fallback_reads_authoritative_server_config() -> None:
    text = RECONCILER.read_text(encoding="utf-8")

    assert "spire-server-config" in text
    assert 'trust_domain\\\"' in text or 'trust_domain\\s*=' in text
    assert 'LIVE_TRUST_DOMAIN="$(resolve_live_spire_trust_domain || true)"' in text
