#!/usr/bin/env python3
import os
from typing import Dict, Set

import yaml
from jinja2 import Template

AUTHZ_DIR = "deploy/infra/istio/templates/authz"

POLICY_TEMPLATE = Template(
    """
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: {{ workload }}-inbound
  namespace: {{ namespace }}
spec:
  action: ALLOW
  rules:
    - from:
{% for src in allowed_sources %}
        - source:
            principals:
              - "spiffe://{{ trust_domain }}/ns/{{ src.namespace }}/sa/{{ src.service_account }}"
{% endfor %}
      to:
        - operation:
            ports:
{% for port in ports %}
              - "{{ port }}"
{% endfor %}
""",
)


def main() -> None:
    with open("deploy/identity/identity-matrix.yaml") as f:
        matrix = yaml.safe_load(f)

    trust_domain = matrix["trust_domain"]
    tiers = matrix["tiers"]
    relations = matrix["relations"]
    ports = matrix["ports"]

    os.makedirs(AUTHZ_DIR, exist_ok=True)

    # Build workload → tier lookup
    tier_of: Dict[str, str] = {}
    for tier, info in tiers.items():
        for w in info["workloads"]:
            tier_of[w] = tier

    # Build allowed-tier map
    allowed: Dict[str, Set[str]] = {tier: set() for tier in tiers}
    for r in relations:
        src = r["from"]
        for dst in r["to"]:
            if dst == "all":
                allowed[src] = set(tiers.keys())
            else:
                allowed[src].add(dst)

    # Generate per-workload policies
    for workload, tier in tier_of.items():
        namespace = workload.split("-")[0]  # simple heuristic
        allowed_sources = []

        for src_workload, src_tier in tier_of.items():
            if src_tier in allowed[src_tier] or src_tier in allowed[tier]:
                allowed_sources.append({"namespace": src_workload.split("-")[0], "service_account": src_workload})

        workload_ports = ports.get(workload, [])

        rendered = POLICY_TEMPLATE.render(
            workload=workload,
            namespace=namespace,
            trust_domain=trust_domain,
            allowed_sources=allowed_sources,
            ports=workload_ports,
        )

        out_path = os.path.join(AUTHZ_DIR, f"{workload}-authz.yaml")
        with open(out_path, "w") as f:
            f.write(rendered)

        print(f"[✓] Generated {out_path}")


if __name__ == "__main__":
    main()
