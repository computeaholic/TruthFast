#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


OPEN_MALFORMED = re.compile(r"(?<!\{)\{\s+\{")
CLOSE_MALFORMED = re.compile(r"(?<!\})\}\s+\}(?!\})")


def _scan_text(path: Path, text: str) -> list[tuple[int, str]]:
    violations: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if OPEN_MALFORMED.search(line):
            violations.append((lineno, line))
            continue
        if CLOSE_MALFORMED.search(line) and ("{{" in line or "{ {" in line or "{{-" in line):
            violations.append((lineno, line))
    return violations


def _scan_file(path: Path) -> list[tuple[int, str]]:
    return _scan_text(path, path.read_text(encoding="utf-8", errors="replace"))


def _iter_scan_paths(paths: list[Path]) -> list[Path]:
    if not paths:
        repo_root = Path(__file__).resolve().parents[2]
        candidates = [repo_root / "platform/deploy", repo_root / "platform/policies"]
        return [p for root in candidates if root.is_dir() for p in sorted(root.rglob("*.y*ml"))]

    results: list[Path] = []
    for path in paths:
        if path.is_dir():
            results.extend(sorted(p for p in path.rglob("*.y*ml") if p.is_file()))
        elif path.is_file():
            results.append(path)
    return results


def main(argv: list[str]) -> int:
    scan_paths = [Path(arg) for arg in argv[1:]]
    had_violation = False
    violations: list[str] = []

    for file_path in _iter_scan_paths(scan_paths):
        for lineno, line in _scan_file(file_path):
            had_violation = True
            violations.append(f"  {file_path}:{lineno}: {line}")

    if had_violation:
        print("CONTRACT_VIOLATION: Malformed Helm template syntax detected (space-padded {{ or }}).")
        print()
        print("Affected lines:")
        for line in violations:
            print(line)
        print()
        print("Valid syntax:   {{ .Release.Namespace }}")
        print("Invalid syntax: { { .Release.Namespace } }")
        print()
        print("Fix: remove the spaces inside the opening {{ and closing }} delimiters.")
        return 2

    print("OK: No malformed Helm template syntax found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
