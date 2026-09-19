#!/usr/bin/env python3
"""Render README.md the way GitHub will render it, and open it.

    ./Scripts/preview-readme.py

GitHub's own renderer does the markdown, through `gh api /markdown`, so what
comes out is what the repository page will show. The stylesheet is the one
GitHub publishes. Images are rewritten to absolute paths on this machine,
because nothing is pushed yet and a relative path in a temporary file resolves
to the wrong place.

Nothing is written into the repository. The page lands in a temporary folder
and is safe to delete.
"""
from __future__ import annotations

import html
import json
import re
import subprocess
import tempfile
import urllib.request
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSS = "https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.css"


def rendered(markdown: str) -> str:
    """GitHub's renderer, in GitHub Flavoured Markdown mode."""
    payload = json.dumps({"text": markdown, "mode": "gfm"})
    out = subprocess.run(
        ["gh", "api", "/markdown", "--input", "-"],
        input=payload, capture_output=True, text=True, check=True,
    )
    return out.stdout


def stylesheet() -> str:
    try:
        with urllib.request.urlopen(CSS, timeout=15) as handle:
            return handle.read().decode()
    except Exception as error:                        # offline is not fatal
        print(f"  no stylesheet ({error}), falling back to plain text")
        return "body{font:16px -apple-system,sans-serif;max-width:860px;margin:2rem auto}"


def absolute(body: str) -> tuple[str, list[str]]:
    """Point every relative src at the file on disk, and report the misses."""
    missing: list[str] = []

    def fix(match: re.Match) -> str:
        src = html.unescape(match.group(1))
        if src.startswith(("http://", "https://", "data:", "file:")):
            return match.group(0)
        target = (ROOT / src).resolve()
        if not target.exists():
            missing.append(src)
        return f'src="{target.as_uri()}"'

    return re.sub(r'src="([^"]+)"', fix, body), missing


def main() -> int:
    readme = ROOT / "README.md"
    body, missing = absolute(rendered(readme.read_text()))
    page = (
        "<!doctype html><meta charset=utf-8>"
        f"<title>{ROOT.name}/README.md</title>"
        f"<style>{stylesheet()}\n"
        ".markdown-body{box-sizing:border-box;max-width:1012px;margin:0 auto;"
        "padding:45px;border:1px solid #d1d9e0;border-radius:6px}"
        "@media(max-width:767px){.markdown-body{padding:15px}}</style>"
        f"<article class=markdown-body>{body}</article>"
    )
    out = Path(tempfile.gettempdir()) / "celeritas-readme.html"
    out.write_text(page)
    print(f"  {out}  ({len(page):,} bytes)")
    for src in missing:
        print(f"  MISSING IMAGE: {src}")
    webbrowser.open(out.as_uri())
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
