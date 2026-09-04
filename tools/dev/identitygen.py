#!/usr/bin/env python3

import hashlib
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "identity" / "identity.yaml"
OUT = ROOT / "identity" / "generated"


def mkdir(p):
    p.mkdir(parents=True, exist_ok=True)


def sha(path):
    data = open(path, "rb").read()
    return hashlib.sha256(data).hexdigest()


def load_identity():
    with open(SRC) as f:
        return yaml.safe_load(f)


def spiffe(trust, ns, sa):
    return f"{trust}/ns/{ns}/sa/{sa}"


def gen_namespace(ns):
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns, "labels": {"tier": "true"}}}


def gen_serviceaccount(ns, sa):
    return {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": ns}}


def gen_registration(trust, ns, sa):
    return {
        "apiVersion": "spire.spiffe.io/v1alpha1",
        "kind": "RegistrationEntry",
        "metadata": {"name": f"{ns}-{sa}".replace("_", "-")},
        "spec": {
            "parentId": f"{trust}/spire/server",
            "spiffeId": spiffe(trust, ns, sa),
            "selectors": [{"type": "k8s", "value": f"sa:{sa}"}, {"type": "k8s", "value": f"ns:{ns}"}],
        },
    }


def gen_istio_policy(trust, ns, workload, sa, tier):
    return {
        "apiVersion": "security.istio.io/v1beta1",
        "kind": "AuthorizationPolicy",
        "metadata": {
            "name": f"{ns}-{workload}-authz",
            "namespace": ns,
        },
        "spec": {
            "selector": {"matchLabels": {"app": workload}},
            "action": "ALLOW",
            "rules": [
                {
                    "from": [{"source": {"principals": [spiffe(trust, ns, sa)]}}],
                    "when": [{"key": "request.auth.audiences", "values": [tier]}],
                },
            ],
        },
    }


def write_yaml(obj, path):
    with open(path, "w") as f:
        yaml.dump(obj, f, sort_keys=False)


def main():
    ident = load_identity()
    trust = ident["trustDomain"]

    # Prepare directories
    dirs = [
        OUT / "sa",
        OUT / "namespaces",
        OUT / "spire",
        OUT / "istio",
        OUT / "policies" / "tiers",
        OUT / "policies" / "services",
    ]
    for d in dirs:
        mkdir(d)

    table = {}

    for ns_def in ident["namespaces"]:
        ns = ns_def["name"]
        tier = ns_def["tier"]

        # Namespace
        write_yaml(gen_namespace(ns), OUT / "namespaces" / f"{ns}.yaml")

        for wd in ns_def["workloads"]:
            sa = wd["serviceAccount"]
            app = wd["name"]

            # ServiceAccount
            write_yaml(gen_serviceaccount(ns, sa), OUT / "sa" / f"{ns}-{sa}.yaml")

            # SPIRE RegistrationEntry
            svid = spiffe(trust, ns, sa)
            write_yaml(gen_registration(trust, ns, sa), OUT / "spire" / f"{ns}-{sa}.yaml")

            # Istio AuthorizationPolicy
            write_yaml(gen_istio_policy(trust, ns, app, sa, tier), OUT / "istio" / f"{ns}-{app}-authz.yaml")

            table[f"{ns}/{app}"] = {"svid": svid, "serviceAccount": sa, "tier": tier}

    # Emit SVID mapping table
    write_yaml(table, OUT / "svids" / "svid-table.yaml")


if __name__ == "__main__":
    main()
