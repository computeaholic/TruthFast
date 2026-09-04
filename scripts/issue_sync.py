#!/usr/bin/env python3
"""Simple dry-run issue sync: read .github/ISSUES/*.md and print a TSV summary.

This script is intentionally read-only and safe for CI dry-run.
"""

from pathlib import Path

base = Path(".github/ISSUES")
files = sorted(base.glob("*.md"))
print("file\ttitle\tfirst_line")
for f in files:
    text = f.read_text().splitlines()
    title = text[0].lstrip("#").strip() if text else ""
    first = text[1] if len(text) > 1 else ""
    print(f"{f.name}\t{title}\t{first}")
