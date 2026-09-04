#!/usr/bin/env python3
"""Simple static site generator for ThreadForge docs.

This script reads `mkdocs.yml` and converts referenced Markdown files into
basic HTML pages under `site/` using Python's `markdown` package when
available. It keeps a minimal, consistent template and copies over any
local assets it finds (images, css) referenced by the source markdown.

Usage:
  python scripts/generate_site.py

This is intentionally lightweight and works offline; if `markdown` package
is not installed it falls back to a very small renderer that handles
headers and paragraphs.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except Exception:
    print("ERROR: pyyaml is required to parse mkdocs.yml. Please pip install pyyaml.")
    raise

try:
    import markdown

    _HAS_MARKDOWN = True
except Exception:
    _HAS_MARKDOWN = False

ROOT = Path(__file__).resolve().parents[1]
MKDOCS = ROOT / "mkdocs.yml"
SITE = ROOT / "site"
DOCS_ROOT = ROOT

TEMPLATE = """<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>{title} - ThreadForge</title>
    <meta name="description" content="ThreadForge — identity-first microcloud docs snapshot.">
    <link rel="stylesheet" href="assets/style.css">
  </head>
  <body>
    <div class="container">
      <header class="site-header">
        <div class="site-brand">
          <h1>ThreadForge</h1>
          <p>Identity-first autonomous microcloud</p>
        </div>
        <nav class="nav">
          <a href="/index.html">Home</a>
          <a href="/docs/">Docs</a>
        </nav>
      </header>

      <div class="main">
        <aside class="aside">
          <h4>Featured Docs</h4>
          <ul>
            {featured_links}
          </ul>
        </aside>

        <div class="content">
          {body}
        </div>
      </div>

      <footer class="site-footer">
        <p>Generated snapshot — Not authoritative. Build locally with <code>mkdocs build --site-dir site</code>.</p>
      </footer>
    </div>
  </body>
</html>
"""


def simple_render(md: str) -> str:
    """Fallback renderer that supports headers, emphasis, lists, and code fences.

    This is more capable than the original naive renderer and will produce
    respectably formatted HTML even when the ``markdown`` package is absent.
    """
    import re

    # basic bold/italic handling
    md = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", md)
    md = re.sub(r"\*(.+?)\*", r"<em>\1</em>", md)

    out: list[str] = []
    in_ul = False
    in_ol = False
    in_code = False
    code_lines: list[str] = []

    for raw in md.splitlines():
        line = raw.rstrip()

        # Code fence handling
        if line.startswith("```"):
            if in_code:
                # close code block
                out.append("<pre><code>" + "\n".join(code_lines) + "</code></pre>")
                code_lines = []
                in_code = False
            else:
                in_code = True
            continue

        if in_code:
            code_lines.append(line)
            continue

        if not line.strip():
            # close any open lists
            if in_ul:
                out.append("</ul>")
                in_ul = False
            if in_ol:
                out.append("</ol>")
                in_ol = False
            out.append("")
            continue

        # Headings
        if line.startswith("# "):
            out.append(f"<h1>{line[2:].strip()}</h1>")
            continue
        if line.startswith("## "):
            out.append(f"<h2>{line[3:].strip()}</h2>")
            continue
        if line.startswith("### "):
            out.append(f"<h3>{line[4:].strip()}</h3>")
            continue

        # Unordered list
        m_ul = re.match(r"^\s*[-*]\s+(.+)", line)
        if m_ul:
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append(f"  <li>{m_ul.group(1).strip()}</li>")
            continue

        # Ordered list
        m_ol = re.match(r"^\s*\d+\.\s+(.+)", line)
        if m_ol:
            if not in_ol:
                out.append("<ol>")
                in_ol = True
            out.append(f"  <li>{m_ol.group(1).strip()}</li>")
            continue

        # Paragraph
        out.append(f"<p>{line}</p>")

    # Close any remaining lists or code
    if in_ul:
        out.append("</ul>")
    if in_ol:
        out.append("</ol>")
    if in_code:
        out.append("<pre><code>" + "\n".join(code_lines) + "</code></pre>")

    return "\n".join(out)


def render_markdown(md: str) -> str:
    if _HAS_MARKDOWN:
        return markdown.markdown(md, extensions=["fenced_code", "codehilite", "toc"])
    return simple_render(md)


def parse_nav(mk: dict[str, Any]) -> list[str]:
    nav = mk.get("nav", [])
    files = set()
    for section in nav:
        for title, path in section.items():
            if isinstance(path, list):
                for p in path:
                    if isinstance(p, dict):
                        for k, v in p.items():
                            files.add(v)
                    else:
                        files.add(p)
            elif isinstance(path, dict):
                for k, v in path.items():
                    files.add(v)
            else:
                files.add(path)
    return sorted(files)


def build_site():
    if not MKDOCS.exists():
        print("mkdocs.yml not found — aborting")
        sys.exit(1)

    raw = yaml.safe_load(MKDOCS.read_text())
    files = parse_nav(raw)

    # Ensure site directories
    if SITE.exists():
        shutil.rmtree(SITE)
    SITE.mkdir(parents=True)
    (SITE / "docs").mkdir(parents=True)

    # Load featured docs list if present (only include these in the /docs index and the sidebar)
    featured_file = ROOT / "scripts" / "site_featured.txt"
    featured = []
    if featured_file.exists():
        for ln in featured_file.read_text().splitlines():
            ln = ln.strip()
            if ln:
                featured.append(ln)

    featured_links_html = []
    if featured:
        for f in featured:
            src = ROOT / f
            if not src.exists():
                continue
            href = str(Path(f).with_suffix(".html"))
            title = Path(f).stem
            featured_links_html.append(f'<li><a href="/{href}">{title}</a></li>')

    # Build index page from README or index.md
    index_md = None
    for candidate in (ROOT / "index.md", ROOT / "README.md", ROOT / "docs" / "index.md"):
        if candidate and candidate.exists():
            index_md = candidate
            break

    featured_join = "\n".join(featured_links_html)
    if index_md is None:
        content = TEMPLATE.format(title="Home", body="<p>No index found</p>", featured_links=featured_join)
        (SITE / "index.html").write_text(content)
    else:
        md = index_md.read_text()
        body = render_markdown(md)
        content = TEMPLATE.format(title="Home", body=body, featured_links=featured_join)
        (SITE / "index.html").write_text(content)

    # Convert files referenced in mkdocs nav
    for f in files:
        source = ROOT / f
        if not source.exists():
            print(f"Skipping missing {f}")
            continue
        target_dir = SITE / Path(f).parent
        target_dir.mkdir(parents=True, exist_ok=True)
        md = source.read_text()
        body = render_markdown(md)
        out = TEMPLATE.format(title=source.stem, body=body, featured_links="\n".join(featured_links_html))
        # write to path relative to site
        outfile = SITE / f.replace(".md", ".html")
        outfile.parent.mkdir(parents=True, exist_ok=True)
        outfile.write_text(out)

    # (Featured list already handled above)
    # Additionally, traverse docs/ tree and render all Markdown files (catch everything)
    docs_root = ROOT / "docs"
    docs_index_entries = []
    if docs_root.exists():
        for md_path in sorted(docs_root.rglob("*.md")):
            rel = md_path.relative_to(ROOT)
            outfile = SITE / rel.with_suffix(".html")
            outfile.parent.mkdir(parents=True, exist_ok=True)
            md = md_path.read_text()
            body = render_markdown(md)
            out = TEMPLATE.format(title=md_path.stem, body=body, featured_links="\n".join(featured_links_html))
            outfile.write_text(out)
            docs_index_entries.append((str(rel.with_suffix(".html")), md_path.stem))

        # Build docs index from featured list (if provided) otherwise include all
        if featured:
            docs_index_body = "<h2>Featured Docs</h2>\n<ul>"
            for f in featured:
                src = ROOT / f
                if not src.exists():
                    continue
                href = str(Path(f).with_suffix(".html"))
                title = Path(f).stem
                entry = f'<li><a href="/{href}">{title}</a></li>'
                docs_index_body += entry
            docs_index_body += "</ul>"
        else:
            docs_index_body = "<h2>Docs index</h2>\n<ul>"
            for href, title in docs_index_entries:
                entry = f'<li><a href="/{href}">{title}</a></li>'
                docs_index_body += entry
            docs_index_body += "</ul>"

        (SITE / "docs" / "index.html").write_text(
            TEMPLATE.format(title="Docs", body=docs_index_body, featured_links="\n".join(featured_links_html)),
        )

    # Copy site assets (if provided)
    assets_src = ROOT / "site_assets"
    if assets_src.exists():
        dst = SITE / "assets"
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(assets_src, dst)

    print(f"Site generated into: {SITE}")


if __name__ == "__main__":
    build_site()
