#!/usr/bin/env python3
"""Build the emoji index the launcher searches.

    python3 Scripts/make-emoji.py

Unicode publishes emoji-test.txt, which is the authoritative list: every emoji,
its qualification status, its group and its CLDR name. That file is the recipe,
so this script downloads it rather than anybody pasting emoji into Swift by
hand, and the output is regenerated whenever Unicode ships a new set.

Only fully-qualified sequences are kept. The unqualified variants are the same
picture with a missing variation selector, and shipping both means every search
returns each emoji twice.

Search words come from the CLDR name plus the group and subgroup, so "heart"
finds the hearts and "flag" finds the flags. ALIASES adds the words people
actually type that Unicode does not use: nobody searches for
"grinning face with smiling eyes" when they want :)
"""
from __future__ import annotations

import json
import re
import urllib.request
from pathlib import Path

SOURCE = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
OUT = Path(__file__).resolve().parent.parent / "Sources/CeleritasKit/Resources/emoji.json"

# What people type, against a word already in the Unicode name.
ALIASES = {
    "grinning": ["smile", "happy"],
    "face with tears of joy": ["lol", "laugh", "funny"],
    "rolling on the floor laughing": ["rofl", "lol"],
    "smiling face with heart-eyes": ["love"],
    "thumbs up": ["+1", "yes", "ok", "approve", "like"],
    "thumbs down": ["-1", "no", "nope"],
    "red heart": ["love"],
    "fire": ["lit", "hot"],
    "party popper": ["celebrate", "congrats", "tada"],
    "rocket": ["ship", "launch", "deploy"],
    "check mark button": ["done", "tick", "yes"],
    "cross mark": ["no", "wrong", "fail"],
    "warning": ["caution", "careful"],
    "bug": ["issue", "defect"],
    "light bulb": ["idea"],
    "eyes": ["looking", "watching"],
    "folded hands": ["please", "thanks", "pray"],
    "clapping hands": ["applause", "well done"],
    "skull": ["dead", "dying"],
    "crying face": ["sad"],
    "loudly crying face": ["sob", "sad"],
    "thinking face": ["hmm"],
    "face with rolling eyes": ["ugh"],
    "hundred points": ["100", "perfect"],
    "money bag": ["cash", "rich"],
    "chart increasing": ["up", "growth"],
    "chart decreasing": ["down", "loss"],
    "hourglass done": ["wait", "slow"],
    "high voltage": ["fast", "power", "zap"],
    "sparkles": ["shiny", "new"],
    "wrench": ["fix", "tool"],
    "hammer": ["build"],
    "package": ["release", "box"],
    "locked": ["secure", "private"],
    "bar chart": ["stats", "graph"],
}


def build() -> list[dict]:
    request = urllib.request.Request(SOURCE, headers={"User-Agent": "celeritas/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        text = response.read().decode("utf-8")

    rows, group, subgroup = [], "", ""
    line_pattern = re.compile(
        r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$")

    for line in text.splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
            continue
        match = line_pattern.match(line)
        if not match:
            continue
        _, char, name = match.groups()
        name = name.strip()

        words = set(re.split(r"[\s\-_,:&]+", name.lower()))
        for source in (group, subgroup):
            words.update(w for w in re.split(r"[\s\-_,:&]+", source.lower()) if w)
        words.update(ALIASES.get(name.lower(), []))
        words.discard("")
        rows.append({"e": char, "n": name, "k": sorted(words)})
    return rows


if __name__ == "__main__":
    emoji = build()
    if len(emoji) < 1000:
        raise SystemExit(f"only {len(emoji)} emoji, the format probably changed")
    OUT.write_text(json.dumps(emoji, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(emoji)} emoji -> {OUT} ({OUT.stat().st_size:,} bytes)")
    for probe in ("fire", "rocket", "thumbs up"):
        hit = next((r for r in emoji if r["n"] == probe), None)
        print(f"  {probe}: {hit['e'] if hit else 'MISSING'}")
