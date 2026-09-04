#!/usr/bin/env python3
"""Generate current Mermaid diagrams from canonical audit evidence."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable, Dict


def load_evidence(audit_dir: Path) -> Dict[str, Any]:
    evidence: Dict[str, Any] = {}
    for root in (audit_dir, audit_dir / "raw"):
        if not root.exists():
            continue
        for json_file in sorted(root.glob("phase_*.json")):
            phase_name = json_file.stem.replace("phase_", "")
            try:
                evidence[phase_name] = json.loads(json_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as error:
                print(f"Warning: Could not load {json_file}: {error}", file=sys.stderr)
    return evidence


def write_diagram(output_file: Path, content: str) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(content.rstrip() + "\n", encoding="utf-8")


def generate_identity_flow(evidence: Dict[str, Any], output_file: Path) -> None:
    identity = evidence.get("identity", {}).get("evidence", {})
    spire_style = "#c8e6c9" if identity.get("spire_dir_present") else "#ffcdd2"
    namespace_style = "#c8e6c9" if identity.get("spire_namespace_present") else "#fff3e0"
    content = f"""graph TD
    A[SPIRE Server] --> B[SPIRE Agents]
    B --> C[SPIFFE SVID Delivery]
    C --> D[Istio Sidecars]
    D --> E[Identity-Bound Workloads]
    E --> F[Proof and Audit Evidence]

    style A fill:{spire_style}
    style B fill:{namespace_style}
    style F fill:#e3f2fd
"""
    write_diagram(output_file, content)


def generate_system_topology(evidence: Dict[str, Any], output_file: Path) -> None:
    runtime = evidence.get("runtime", {}).get("evidence", {})
    observability = evidence.get("observability", {}).get("evidence", {})
    runtime_style = "#c8e6c9" if runtime.get("runtime_dir_present") else "#ffcdd2"
    observability_style = "#c8e6c9" if observability.get("observability_dir_present") else "#ffcdd2"
    content = f"""graph TB
    subgraph Control Plane
        SPIRE[SPIRE]
        ISTIO[Istio]
        KYVERNO[Kyverno]
    end

    subgraph Runtime Plane
        API[threadforge-api]
        OPERATOR[Operator Runtime]
        REGISTRY[Internal Registry]
    end

    subgraph Observability Plane
        GRAFANA[Grafana]
        PROMETHEUS[Prometheus]
        TEMPO[Tempo]
        LOKI[Loki]
    end

    subgraph Audit Plane
        AUDIT[Canonical Audit]
        SBOM[SBOM Generator]
        FORGESEC[ForgeSec]
    end

    SPIRE --> ISTIO
    ISTIO --> API
    KYVERNO --> API
    API --> OPERATOR
    API --> REGISTRY
    API --> GRAFANA
    API --> PROMETHEUS
    API --> TEMPO
    API --> LOKI
    AUDIT --> SBOM
    AUDIT --> FORGESEC

    style API fill:{runtime_style}
    style GRAFANA fill:{observability_style}
    style AUDIT fill:#e3f2fd
"""
    write_diagram(output_file, content)


def generate_audit_pipeline(evidence: Dict[str, Any], output_file: Path) -> None:
    repo_authority = evidence.get("repo_authority", {}).get("status", "WARN")
    authority_style = "#c8e6c9" if repo_authority == "PASS" else "#ffcdd2"
    content = f"""graph LR
    A[make audit] --> B[run_full_audit.sh]
    B --> C[Identity, Istio, Observability, Runtime]
    B --> D[Repository Output Authority]
    B --> E[ForgeSec Wiring]
    B --> F[generate_sbom.py]
    B --> G[generate_mermaids.py]
    F --> H[artifacts/audit/<run>/sbom]
    G --> I[artifacts/mermaid/<run>]
    B --> J[audit_report.json]
    B --> K[meta/output_authority_matrix.json]

    style D fill:{authority_style}
    style H fill:#fff3e0
    style I fill:#fff3e0
"""
    write_diagram(output_file, content)


def generate_forgesec_flow(evidence: Dict[str, Any], output_file: Path) -> None:
    forgesec = evidence.get("forgesec", {}).get("evidence", {})
    manifest_style = "#c8e6c9" if forgesec.get("suite_manifests_present") else "#ffcdd2"
    host_style = "#c8e6c9" if forgesec.get("registry_host_current") else "#ffcdd2"
    content = f"""graph TD
    A[make forgesec] --> B[forgesec.mk]
    B --> C[identity-job.yaml]
    B --> D[surface-job.yaml]
    C --> E[forgesec.sh suite identity]
    D --> F[forgesec.sh suite surface]
    E --> G[artifacts/forgesec/<run>/identity]
    F --> H[artifacts/forgesec/<run>/surface]
    G --> I[security gate result]
    H --> I

    style C fill:{manifest_style}
    style D fill:{manifest_style}
    style E fill:{host_style}
    style F fill:{host_style}
"""
    write_diagram(output_file, content)


def generate_master_system_diagram(evidence: Dict[str, Any], output_file: Path) -> None:
    repo_authority = evidence.get("repo_authority", {}).get("status", "WARN")
    authority_style = "#c8e6c9" if repo_authority == "PASS" else "#ffcdd2"
    content = f"""graph TB
    subgraph Identity
        SPIRE[SPIRE]
        SVID[SPIFFE Identity]
    end

    subgraph Enforcement
        ISTIO[Istio mTLS]
        KYVERNO[Kyverno Admission]
    end

    subgraph Runtime
        API[threadforge-api]
        WORKLOADS[Service Workloads]
        REGISTRY[Internal Registry]
    end

    subgraph Evidence
        PROOF[artifacts/proof]
        AUDIT[artifacts/audit]
        MERMAID[artifacts/mermaid]
        FORGESEC[artifacts/forgesec]
        RUNTIME[artifacts/runtime]
    end

    SPIRE --> SVID --> ISTIO --> API --> WORKLOADS
    KYVERNO --> WORKLOADS
    API --> REGISTRY
    WORKLOADS --> PROOF
    WORKLOADS --> AUDIT
    AUDIT --> MERMAID
    AUDIT --> FORGESEC
    WORKLOADS --> RUNTIME

    style AUDIT fill:{authority_style}
    style MERMAID fill:#fff3e0
    style FORGESEC fill:#fff3e0
"""
    write_diagram(output_file, content)


def generate_diagrams(audit_dir: Path, output_dir: Path) -> list[Path]:
    evidence = load_evidence(audit_dir)
    generators: dict[str, Callable[[Dict[str, Any], Path], None]] = {
        "identity_flow": generate_identity_flow,
        "system_topology": generate_system_topology,
        "audit_pipeline": generate_audit_pipeline,
        "forgesec_flow": generate_forgesec_flow,
        "master_system": generate_master_system_diagram,
    }
    written: list[Path] = []
    for name, generator in generators.items():
        output_file = output_dir / f"{name}.mmd"
        generator(evidence, output_file)
        written.append(output_file)
    return written


def resolve_output_dir(audit_dir: Path, output_dir: Path | None) -> Path:
    if output_dir is not None:
        return output_dir.resolve()
    repo_root = Path(__file__).resolve().parents[1]
    return (repo_root / "artifacts" / "mermaid" / audit_dir.name).resolve()


def main() -> int:
    if len(sys.argv) not in {2, 3}:
        print("Usage: generate_mermaids.py <audit_directory> [mermaid_output_dir]", file=sys.stderr)
        return 1

    audit_dir = Path(sys.argv[1]).resolve()
    output_dir = resolve_output_dir(audit_dir, Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    if not audit_dir.exists() or not audit_dir.is_dir():
        print(f"Error: {audit_dir} is not a valid directory", file=sys.stderr)
        return 1

    written = generate_diagrams(audit_dir, output_dir)
    for path in written:
        print(f"Generated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
