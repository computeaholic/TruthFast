#!/usr/bin/env python3
"""Generate a deterministic CycloneDX SBOM for the repository."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


REQ_PATTERN = re.compile(r"^(?P<name>[A-Za-z0-9_.-]+)(?P<specifier>(?:==|>=|<=|~=|!=|>|<).+)?$")
IMAGE_PATTERN = re.compile(r"image:\s*[\"']?(?P<image>[^\s\"']+)")
SBOMComponent = dict[str, object]


def parse_requirement_line(line: str) -> tuple[str, str] | None:
    candidate = line.split("#", 1)[0].strip()
    if not candidate or candidate.startswith(("-r", "--", "-e", ".")):
        return None
    match = REQ_PATTERN.match(candidate)
    if not match:
        return None
    name = match.group("name")
    specifier = (match.group("specifier") or "").strip()
    version = specifier[2:] if specifier.startswith("==") else specifier or "unspecified"
    return name, version


def collect_python_components(repo_root: Path) -> list[SBOMComponent]:
    components: dict[tuple[str, str], SBOMComponent] = {}
    requirement_files = [repo_root / "requirements.txt", *sorted((repo_root / "requirements").glob("*.txt"))]
    for file_path in requirement_files:
        if not file_path.exists():
            continue
        for line in file_path.read_text(encoding="utf-8").splitlines():
            parsed = parse_requirement_line(line)
            if parsed is None:
                continue
            name, version = parsed
            components[(name.lower(), version)] = {
                "bom-ref": f"pkg:pypi/{name.lower()}@{version}",
                "type": "library",
                "name": name,
                "version": version,
                "purl": f"pkg:pypi/{name.lower()}@{version}",
                "properties": [{"name": "threadforge:source", "value": str(file_path.relative_to(repo_root))}],
            }
    return sorted(components.values(), key=lambda item: (str(item["name"]).lower(), str(item["version"])))


def collect_image_refs(repo_root: Path) -> list[str]:
    images: set[str] = set()
    collector = repo_root / "scripts" / "supply_chain" / "collect_images.sh"
    if collector.exists() and collector.is_file():
        result = subprocess.run(
            [str(collector), "--scope", "cluster"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("["):
                    images.add(stripped)
    for file_path in sorted((repo_root / "platform").rglob("*.yaml")):
        for line in file_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = IMAGE_PATTERN.search(line)
            if match:
                images.add(match.group("image"))
    for file_path in sorted(repo_root.rglob("*Dockerfile*")):
        for line in file_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("FROM "):
                images.add(line.split()[1])
    return sorted(images)


def collect_container_components(repo_root: Path) -> list[SBOMComponent]:
    components: list[SBOMComponent] = []
    for image in collect_image_refs(repo_root):
        if "@" in image:
            name, version = image.split("@", 1)
        elif ":" in image.rsplit("/", 1)[-1]:
            name, version = image.rsplit(":", 1)
        else:
            name, version = image, "unversioned"
        components.append(
            {
                "bom-ref": f"container:{image}",
                "type": "container",
                "name": name,
                "version": version,
                "purl": f"pkg:oci/{name}@{version}" if version != "unversioned" else f"pkg:oci/{name}",
                "properties": [{"name": "threadforge:image", "value": image}],
            }
        )
    return components


def build_bom(repo_root: Path) -> dict[str, object]:
    components = collect_python_components(repo_root) + collect_container_components(repo_root)
    digest = hashlib.sha256(json.dumps(components, sort_keys=True).encode("utf-8")).hexdigest()
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{digest[:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "ThreadForge",
                "version": digest[:12],
            },
            "tools": [
                {
                    "vendor": "ThreadForge",
                    "name": "audit-generate-sbom",
                    "version": "1",
                }
            ],
        },
        "components": components,
        "dependencies": [],
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: generate_sbom.py <repo_root> <output_path>", file=sys.stderr)
        return 1
    repo_root = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bom = build_bom(repo_root)
    output_path.write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
