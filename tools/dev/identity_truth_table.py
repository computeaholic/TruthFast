import csv
import json
from pathlib import Path

import yaml

ENTRIES = Path("deploy/infra/spire/templates/registration-entries.yaml")


def load_entries():
    return list(yaml.safe_load_all(ENTRIES.read_text()))


def extract_fields(e):
    sid = e["spec"]["spiffeId"]
    parts = sid.split("/")
    return {
        "name": e["metadata"]["name"],
        "spiffeId": sid,
        "tier": parts[parts.index("tier") + 1],
        "cluster": parts[parts.index("cluster-alpha")],
        "namespace": parts[parts.index("ns") + 1],
        "serviceaccount": parts[parts.index("sa") + 1],
    }


def main():
    entries = load_entries()
    rows = [extract_fields(e) for e in entries]

    # Markdown
    md = ["# Identity Truth Table\n"]
    md.append("| Name | Tier | Namespace | SA | SPIFFE ID |")
    md.append("|------|------|-----------|----|-----------|")
    for r in rows:
        md.append(f"| {r['name']} | {r['tier']} | {r['namespace']} | {r['serviceaccount']} | `{r['spiffeId']}` |")
    Path("identity_truth_table.md").write_text("\n".join(md))

    # CSV
    with open("identity_truth_table.csv", "w") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    # JSON
    Path("identity_truth_table.json").write_text(json.dumps(rows, indent=2))

    print("✔ Truth table emitted: MD, CSV, JSON")


if __name__ == "__main__":
    main()
