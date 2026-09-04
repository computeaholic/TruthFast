#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


def parse_entries_yaml(text: str) -> dict[str, list[dict[str, Any]]]:
    entries: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    in_selectors = False

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()

        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "entries:":
            continue

        entry_match = re.match(r"^\s*-\s*spiffeID:\s*(\S+)\s*$", line)
        if entry_match:
            if current is not None:
                entries.append(current)
            current = {
                "spiffeID": entry_match.group(1),
                "parentID": "",
                "ttl": 0,
                "selectors": [],
            }
            in_selectors = False
            continue

        if current is None:
            continue

        spiffe_match = re.match(r"^\s*spiffeID:\s*(\S+)\s*$", line)
        if spiffe_match:
            current["spiffeID"] = spiffe_match.group(1)
            continue

        parent_match = re.match(r"^\s*parentID:\s*(\S+)\s*$", line)
        if parent_match:
            current["parentID"] = parent_match.group(1)
            continue

        ttl_match = re.match(r"^\s*ttl:\s*(\d+)\s*$", line)
        if ttl_match:
            current["ttl"] = int(ttl_match.group(1))
            continue

        if re.match(r"^\s*selectors:\s*$", line):
            in_selectors = True
            continue

        if in_selectors:
            selector_match = re.match(r"^\s*-\s*(\S+)\s*$", line)
            if selector_match:
                current["selectors"].append(selector_match.group(1))

    if current is not None:
        entries.append(current)

    return {"entries": entries}


def load_document(path: Path) -> dict[str, Any]:
    text = path.read_text()
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        loaded = json.loads(text)
        if isinstance(loaded, list):
            return {"entries": loaded}
        if isinstance(loaded, dict):
            return loaded
        raise SystemExit(f"unsupported JSON top-level type in {path}")
    return parse_entries_yaml(text)


def spiffe_to_string(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        trust_domain = value.get("trust_domain") or value.get("trustDomain")
        path = value.get("path")
        if isinstance(trust_domain, str) and isinstance(path, str) and trust_domain and path:
            return f"spiffe://{trust_domain}{path}"
    raise SystemExit(f"invalid SPIFFE ID value: {value!r}")


def selector_to_string(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        selector_type = value.get("type")
        selector_value = value.get("value")
        if isinstance(selector_type, str) and isinstance(selector_value, str):
            return f"{selector_type}:{selector_value}"
    raise SystemExit(f"invalid selector value: {value!r}")


def canonical_parent_id(parent_id: str) -> str:
    match = re.fullmatch(r"spiffe://([^/]+)/spire/agent/k8s_psat/([^/]+)/[^/]+", parent_id)
    if match:
        trust_domain, cluster_name = match.groups()
        return f"spiffe://{trust_domain}/spire/agent/k8s_psat/{cluster_name}-cluster"
    return parent_id


def normalize_entry(entry: dict[str, Any]) -> dict[str, Any]:
    spiffe_id = spiffe_to_string(entry.get("spiffe_id") or entry.get("spiffeID"))
    parent_id = canonical_parent_id(spiffe_to_string(entry.get("parent_id") or entry.get("parentID")))
    selectors = sorted({selector_to_string(selector) for selector in (entry.get("selectors") or [])})
    ttl = entry.get("x509_svid_ttl")
    if ttl is None:
        ttl = entry.get("x509SvidTtl")
    if ttl is None:
        ttl = entry.get("ttl")
    try:
        ttl_value = int(ttl or 0)
    except (TypeError, ValueError) as err:
        raise SystemExit(f"invalid TTL value: {ttl!r}") from err

    return {
        "parent_id": parent_id,
        "selectors": selectors,
        "spiffe_id": spiffe_id,
        "ttl": ttl_value,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <entries.(json|yaml)>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    document = load_document(path)
    raw_entries = document.get("entries")
    if not isinstance(raw_entries, list):
        raise SystemExit(f"entries list missing in {path}")

    normalized = [normalize_entry(entry) for entry in raw_entries if isinstance(entry, dict)]
    normalized.sort(key=lambda item: (item["spiffe_id"], item["parent_id"], tuple(item["selectors"])))

    json.dump({"entries": normalized}, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
