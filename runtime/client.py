#!/usr/bin/env python3
"""Ask a model to choose a tool.

One OpenAI-shaped client. The host is configuration, never inferred from the
key: an Orbio key sent to a different OpenAI-shaped host returns "Missing
Authentication header", which reads like a broken request and sends you
debugging your own code.

    CELERITY_BASE   defaults to Orbio's gateway
    CELERITY_KEY    the key for that host

A transport failure is marked `transport: True` and must never be scored as a
wrong answer. Twelve models run concurrently once produced a complete, plausible
and entirely false leaderboard, because 429s counted as model mistakes.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from executor import schema  # noqa: E402

DEFAULT_BASE = "https://www.orbio.so/api/v1"
RETRY_STATUS = {429, 500, 502, 503, 504}
MAX_RETRIES = 5

SYSTEM = (
    "You control a Mac. Choose exactly one tool for the user's request and "
    "supply its arguments. If the request is ambiguous, unsupported, missing "
    "information, or not about this Mac, call intent_unclear instead of "
    "guessing."
)


def _bare(name: str | None) -> str | None:
    """Some providers namespace the tool they chose, returning
    `default_api.battery_status`. That is the right tool with a prefix on it."""
    if name and "." in name:
        return name.rsplit(".", 1)[-1]
    return name


def ask(prompt: str, model: str, tools: list[dict] | None = None,
        base: str | None = None, key: str | None = None,
        require_tool: bool = False, timeout: int = 60,
        messages: list[dict] | None = None) -> dict:
    """Send one request. Returns the chosen tool, arguments, cost and latency."""
    base = (base or os.environ.get("CELERITY_BASE") or DEFAULT_BASE).rstrip("/")
    key = key or os.environ.get("CELERITY_KEY") or ""
    body = {
        "model": model,
        "temperature": 0,
        "max_tokens": 400,
        "messages": messages if messages is not None else
                    [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "tools": tools if tools is not None else schema(),
        "tool_choice": "required" if require_tool else "auto",
    }
    payload = json.dumps(body).encode()
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    started = time.time()
    data = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(f"{base}/chat/completions",
                                         data=payload, headers=headers)
            # urlopen has no default timeout. One hung provider must not stall
            # a whole benchmark run.
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.load(resp)
            break
        except urllib.error.HTTPError as e:
            detail = e.read()[:200].decode(errors="replace")
            if e.code in RETRY_STATUS and attempt < MAX_RETRIES:
                time.sleep(2 ** attempt)
                continue
            return {"ok": False, "transport": True,
                    "error": f"http {e.code}: {detail}",
                    "seconds": round(time.time() - started, 2)}
        except Exception as e:                                   # noqa: BLE001
            if attempt < MAX_RETRIES:
                time.sleep(2 ** attempt)
                continue
            return {"ok": False, "transport": True,
                    "error": f"{type(e).__name__}: {e}",
                    "seconds": round(time.time() - started, 2)}

    seconds = round(time.time() - started, 2)
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    calls = message.get("tool_calls") or []
    usage = data.get("usage") or {}

    out = {
        "ok": True,
        "seconds": seconds,
        "retries": attempt,
        "cost": usage.get("cost"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "finish_reason": choice.get("finish_reason"),
        "text": message.get("content"),
    }

    if not calls:
        # Prose instead of a tool call is a result, not an error. Whether it is
        # a failure depends on the task.
        out["tool"] = None
        out["args"] = None
        return out

    fn = calls[0].get("function") or {}
    out["tool"] = _bare(fn.get("name"))
    raw = fn.get("arguments")
    try:
        out["args"] = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError:
        out["args"] = None
        out["bad_arguments"] = raw
    out["extra_calls"] = [_bare((c.get("function") or {}).get("name")) for c in calls[1:]]
    return out


if __name__ == "__main__":
    model = os.environ.get("CELERITY_MODEL", "google/gemini-2.5-flash-lite")
    print(json.dumps(ask(" ".join(sys.argv[1:]) or "what's my battery", model), indent=1))
