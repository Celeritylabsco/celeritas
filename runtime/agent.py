#!/usr/bin/env python3
"""The agent loop.

The model takes a turn, we run what it chose, we hand back the result, it takes
another turn. It stops when it answers in prose, calls intent_unclear, or runs
out of turns.

The executor is an argument, never imported directly. A benchmark run must not
send real mail or write to a real calendar, so it passes a simulated one. The
app passes the real one.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import ask            # noqa: E402
from executor import run, schema  # noqa: E402

MAX_TURNS = 5

# The date is in the prompt on every request. A model should never spend a turn
# asking what day it is, and three failures in the first run were exactly that.
# The prompt is assembled from parts so each one can be tested alone. Three
# changes went in together once and accuracy fell, which told us the lump was
# worse and nothing about which part did it.
#
# CELERITY_PROMPT: comma separated, any of  caps,noprose,categories
#   caps        list what the Mac can do, rather than leaving the model to
#               infer a domain from the tool schemas
#   noprose     forbid answering in text when a tool applies
#   categories  name the intent_unclear reason categories in the prompt

HEAD = """You control a Mac with a fixed set of tools. Choose one tool at a time.

Today is {today}. The time is {now}."""

CAPS = """
What you can do:
- Calendar: list events for a day, create an event, report the next one, delete one.
- Mail: send a message, count unread, list recent, search by subject.
- Files: find by name, open, list recent, list largest, move, trash.
- Notes: create, search by title, read one.
- Reminders: create with a due date, list outstanding, mark complete.
- System: battery, disk space, volume, mute, dark mode, lock screen, running
  processes, memory pressure, wifi network, current date and time."""

NOPROSE = """
- Never answer in plain text when a tool applies. Call the tool."""

CATEGORIES = """
- Call intent_unclear when the request is ambiguous, off topic, incomplete, or
  asks for something the tools cannot do."""

TAIL = """
- After a tool returns, either call another tool or reply in one short sentence.
- Never call the same tool twice with the same arguments."""


def variants() -> set[str]:
    raw = os.environ.get("CELERITY_PROMPT", "")
    return {v.strip() for v in raw.split(",") if v.strip()}


def _system() -> str:
    d = datetime.now()
    v = variants()
    out = HEAD.format(today=d.strftime("%A %d %B %Y"), now=d.strftime("%H:%M"))
    if "caps" in v:
        out += "\n" + CAPS
    out += "\n\nRules:"
    if "noprose" in v:
        out += NOPROSE
    if "categories" in v:
        out += CATEGORIES
    out += TAIL
    return out


def loop(prompt: str, model: str, execute: Callable[..., dict] = run,
         tools: list[dict] | None = None, max_turns: int = MAX_TURNS,
         confirm_destructive: bool = False, **ask_kwargs) -> dict:
    """Run one request to completion. Returns the whole trace."""
    tools = tools if tools is not None else schema()
    messages = [{"role": "system", "content": _system()},
                {"role": "user", "content": prompt}]

    calls: list[dict] = []
    cost = 0.0
    seconds = 0.0

    for turn in range(max_turns):
        # tool_choice is "auto" by default because it is the only setting every
        # provider accepts. Asking for "required" makes the gateway fail to route
        # several models, reporting "No provider is currently serving this model",
        # so requiring it would compare models under different conditions.
        #
        # CELERITY_TOOL_CHOICE=required forces it on the first turn instead, for
        # models that support it. Reported separately, never mixed into one table.
        require = (os.environ.get("CELERITY_TOOL_CHOICE", "auto") == "required"
                   and turn == 0)
        r = ask(prompt, model, tools=tools, messages=messages,
                require_tool=require, **ask_kwargs)
        seconds += r.get("seconds") or 0
        cost += r.get("cost") or 0

        if not r.get("ok"):
            return {"ok": False, "error": r.get("error"),
                    "transport": bool(r.get("transport")), "calls": calls,
                    "turns": turn + 1, "seconds": round(seconds, 2), "cost": cost}

        tool = r.get("tool")
        if tool is None:
            # Prose instead of a tool call. That ends the run, and whether it
            # is a success depends on the task, not on us.
            return {"ok": True, "calls": calls, "text": r.get("text"),
                    "turns": turn + 1, "seconds": round(seconds, 2), "cost": cost,
                    "stopped": "answered"}

        args = r.get("args") or {}
        result = execute(tool, args, confirm=confirm_destructive)
        calls.append({"tool": tool, "args": args, "result": result})

        if tool == "intent_unclear":
            return {"ok": True, "calls": calls, "turns": turn + 1,
                    "seconds": round(seconds, 2), "cost": cost,
                    "stopped": "refused"}

        messages.append({"role": "assistant", "content": None,
                         "tool_calls": [{"id": f"c{turn}", "type": "function",
                                         "function": {"name": tool,
                                                      "arguments": json.dumps(args)}}]})
        messages.append({"role": "tool", "tool_call_id": f"c{turn}",
                         "content": json.dumps(result)[:1500]})

    return {"ok": True, "calls": calls, "turns": max_turns,
            "seconds": round(seconds, 2), "cost": cost, "stopped": "max_turns"}


if __name__ == "__main__":
    model = os.environ.get("CELERITY_MODEL", "LFM2.5-1.2B")
    out = loop(" ".join(sys.argv[1:]) or "what's my battery", model)
    print(json.dumps(out, indent=1)[:1200])
