import json
from pathlib import Path

import yaml

ENTRIES = Path("deploy/infra/spire/templates/registration-entries.yaml")


def load_entries():
    return list(yaml.safe_load_all(ENTRIES.read_text()))


def generate_graphviz(entries):
    lines = ["digraph G {", '  rankdir="LR";', "  node [shape=box, fontsize=10];"]
    for e in entries:
        name = e["metadata"]["name"]
        spiffe = e["spec"]["spiffeId"]
        parent = e["spec"]["parentId"]
        lines.append(f'  "{parent}" -> "{spiffe}";')
    lines.append("}")
    return "\n".join(lines)


def generate_markdown(entries):
    out = ["# Identity Graph\n"]
    out.append("| Name | SPIFFE ID | Parent | Selectors |")
    out.append("|------|-----------|--------|-----------|")
    for e in entries:
        out.append(
            f"| {e['metadata']['name']} | `{e['spec']['spiffeId']}` | "
            f"`{e['spec']['parentId']}` | `{e['spec']['selectors']}` |",
        )
    return "\n".join(out)


def main():
    entries = load_entries()
    graphviz = generate_graphviz(entries)
    md = generate_markdown(entries)

    Path("identity_graph.dot").write_text(graphviz)
    Path("identity_graph.md").write_text(md)
    Path("identity_graph.json").write_text(json.dumps(entries, indent=2))

    print("✔ Identity graph emitted:")
    print(" - identity_graph.dot")
    print(" - identity_graph.md")
    print(" - identity_graph.json")


if __name__ == "__main__":
    main()
