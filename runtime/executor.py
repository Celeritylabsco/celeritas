#!/usr/bin/env python3
"""Run one tool by name.

The model never writes a command. It names a tool and supplies arguments, and
this module substitutes those arguments into a script we wrote by hand. Every
value is escaped before substitution, and that escaping is the security
boundary for the whole application.

Five things the script templates cannot do for themselves:

  * `~` is not expanded inside `do shell script "... '{path}'"`, so path
    parameters are expanded here.
  * Scriptable apps raise -600 when they are not running, so any app-targeted
    tool launches its app first with `open -ga`.
  * AppleScript date literals are locale dependent: `date "August 5, 2026"` is
    a syntax error on a machine formatting dates as `5 August 2026`. Dates are
    parsed here and injected as plain numbers, which every locale agrees on.
  * An empty integer substitution leaves `head -` and a syntax error, so a
    missing number becomes a default rather than a blank.
  * `mdfind` matches substrings and has no glob syntax, so a wildcard from the
    model silently returns nothing and is stripped.
  * A value can carry a quote. Inside an AppleScript literal a double quote
    ends the string; inside `do shell script "... '{path}'"` a single quote
    ends the shell word. Both are neutralised, the second one only for scripts
    that actually shell out.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

TOOLS: dict[str, dict] = {
    t["name"]: t
    for t in json.loads((Path(__file__).parents[1] / "tools" / "tools.json").read_text())
}

# Apps that must be running before they can be scripted. Finder is not here:
# it is always running, and launching it puts a window on screen for tools that
# never touch it.
LAUNCHABLE = {"Mail", "Calendar", "Notes", "Reminders"}

# Used when the model omits a count. Every integer parameter in tools.json is a
# limit of some kind, so one default serves them all.
DEFAULT_INT = 10

_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday",
             "saturday", "sunday"]
_MONTHS = ["january", "february", "march", "april", "may", "june", "july",
           "august", "september", "october", "november", "december"]


def parse_when(text: str) -> datetime:
    """Turn a natural date phrase into a datetime.

    Handles the phrasings people actually type: "tomorrow at 3", "friday",
    "next tuesday 09:30", "March 4", "2026-03-04". Anything unrecognised falls
    back to today, and a missing time falls back to 9am.
    """
    t = (text or "").strip().lower()
    base = datetime.now().replace(second=0, microsecond=0)

    hour = minute = None
    m = re.search(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)", t)
    if m:
        hour = int(m.group(1)) % 12
        minute = int(m.group(2) or 0)
        if m.group(3) == "pm":
            hour += 12
    else:
        m = re.search(r"\b(\d{1,2}):(\d{2})\b", t)
        if m:
            hour, minute = int(m.group(1)), int(m.group(2))

    day = None
    if "tomorrow" in t:
        day = base + timedelta(days=1)
    elif "yesterday" in t:
        day = base - timedelta(days=1)
    elif "today" in t or "tonight" in t:
        day = base
    else:
        for i, name in enumerate(_WEEKDAYS):
            if name in t:
                ahead = (i - base.weekday()) % 7
                if ahead == 0 or "next" in t:
                    ahead = ahead or 7
                day = base + timedelta(days=ahead)
                break

    if day is None:
        m = re.search(r"([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?", t)
        if m and m.group(1) in _MONTHS:
            day = base.replace(year=int(m.group(3) or base.year),
                               month=_MONTHS.index(m.group(1)) + 1,
                               day=int(m.group(2)))
        else:
            m = re.search(r"(\d{4})-(\d{2})-(\d{2})", t)
            if m:
                day = base.replace(year=int(m.group(1)), month=int(m.group(2)),
                                   day=int(m.group(3)))

    if day is None:
        day = base
    if hour is None:
        hour, minute = 9, 0
    return day.replace(hour=hour, minute=minute, second=0, microsecond=0)


def _applescript_safe(value) -> str:
    """Escape a value for use inside an AppleScript string literal."""
    s = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return "".join(ch for ch in s if ch == "\t" or ord(ch) >= 32)


def _shell_safe(value: str) -> str:
    """Neutralise single quotes for a value sitting inside '...' in a shell
    command. Applied on top of the AppleScript escaping, never instead of it."""
    return value.replace("'", "'\"'\"'")


def run(name: str, args: dict | None = None, confirm: bool = False,
        timeout: int = 45) -> dict:
    args = args or {}
    tool = TOOLS.get(name)
    if tool is None:
        return {"ok": False, "error": f"unknown tool: {name}"}

    unexpected = set(args) - set(tool["params"])
    if unexpected:
        return {"ok": False, "error": f"unknown arguments: {sorted(unexpected)}"}

    if tool["destructive"] and not confirm:
        return {"ok": False, "needs_confirmation": True,
                "error": "destructive tool requires confirm=True",
                "description": tool["description"]}

    script = tool["script"]
    shells_out = "do shell script" in script

    for key, spec in tool["params"].items():
        raw = args.get(key, "")

        if spec == "date":
            when = parse_when(str(raw))
            for suffix, number in (("y", when.year), ("mo", when.month),
                                   ("d", when.day), ("h", when.hour),
                                   ("mi", when.minute)):
                script = script.replace("{" + key + "_" + suffix + "}", str(number))
            value = when.strftime("%Y-%m-%d %H:%M")
        elif spec == "integer":
            try:
                value = str(int(str(raw).strip()))
            except (TypeError, ValueError):
                value = str(DEFAULT_INT)
        else:
            value = str(raw)

        if "path" in key or key == "dest":
            value = os.path.expanduser(value)

        # mdfind matches substrings and has no glob syntax, so a model writing
        # "*.pdf" gets nothing back. Wildcards are stripped rather than trusted.
        if name == "find_file" and key == "name":
            value = value.replace("*", "").replace("?", "").lstrip(".")

        # Shell escaping first: it introduces double quotes of its own, which
        # the AppleScript pass then has to escape. The other order leaves them
        # raw and the script fails to parse.
        if shells_out and spec != "integer":
            value = _shell_safe(value)
        value = _applescript_safe(value)
        script = script.replace("{" + key + "}", value)

    leftover = re.findall(r"\{([a-z_]+)\}", script)
    if leftover:
        return {"ok": False, "error": f"unfilled placeholders: {sorted(set(leftover))}"}

    # Only launch when the script actually addresses the app. Several tools
    # are named after an app for grouping but run a shell command instead, and
    # launching for those opens a window the user did not ask for.
    app = tool["app"]
    if app in LAUNCHABLE and f'tell application "{app}"' in script:
        # AppleScript's own `launch` verb fails with -600 on some sandboxed
        # apps, so the app is started out of band and only then scripted.
        subprocess.run(["open", "-ga", app], capture_output=True, timeout=15)

    try:
        p = subprocess.run(["osascript", "-e", script], capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timeout after {timeout}s"}

    if p.returncode != 0:
        return {"ok": False, "error": (p.stderr or "").strip()[:300]}
    return {"ok": True, "result": (p.stdout or "").strip()}


def schema(names: list[str] | None = None) -> list[dict]:
    """OpenAI-style tool schema, for the whole set or a named subset."""
    chosen = TOOLS.values() if names is None else [TOOLS[n] for n in names if n in TOOLS]
    out = []
    for t in chosen:
        props = {
            k: {"type": "integer" if v == "integer" else "string"}
            for k, v in t["params"].items()
        }
        out.append({"type": "function", "function": {
            "name": t["name"],
            "description": t["description"] + (" [DESTRUCTIVE]" if t["destructive"] else ""),
            "parameters": {"type": "object", "properties": props,
                           "required": list(props)},
        }})
    return out


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        payload = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        print(json.dumps(run(sys.argv[1], payload, confirm="--confirm" in sys.argv), indent=1))
    else:
        print(f"{len(TOOLS)} tools")
        for t in TOOLS.values():
            mark = "!" if t["destructive"] else " "
            print(f" {mark} {t['app']:<10} {t['name']}")
