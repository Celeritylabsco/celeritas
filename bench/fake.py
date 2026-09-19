#!/usr/bin/env python3
"""A simulated Mac, for benchmark runs.

A benchmark that called the real tools would send mail, create calendar events
and move files, every run, on whoever's machine happened to be testing. So runs
go through this instead: it holds state, mutates it the way the real tool would,
and returns something plausible.

Verifiers read `state` afterwards. Scoring the end state is the point; how the
model got there is its business.
"""
from __future__ import annotations

import copy
from datetime import datetime

BASE = {
    "volume": 50,
    "muted": False,
    "dark_mode": False,
    "locked": False,
    "events": [],          # {title, start}
    "reminders": [],       # {title, due, completed}
    "notes": [{"title": "Groceries", "body": "oats, milk"}],
    "sent": [],            # {to, subject, body}
    "trash_emptied": False,
    "moved": [],           # {path, dest}
    "trashed": [],         # path
}

FILES = [
    "/Users/you/Documents/invoice-september.pdf",
    "/Users/you/Documents/meeting-notes.txt",
    "/Users/you/Downloads/holiday.mov",
]


class FakeMac:
    def __init__(self) -> None:
        self.state = copy.deepcopy(BASE)
        self.calls: list[tuple[str, dict]] = []

    def execute(self, name: str, args: dict | None = None,
                confirm: bool = False, **_) -> dict:
        args = args or {}
        self.calls.append((name, args))
        s = self.state

        # Destructive tools refuse without confirmation here too, so a
        # benchmark measures the same gate the app enforces.
        destructive = {"delete_event", "move_file", "trash_file", "empty_trash"}
        if name in destructive and not confirm:
            return {"ok": False, "needs_confirmation": True,
                    "error": "destructive tool requires confirm=True"}

        def ok(result):
            return {"ok": True, "result": result}

        match name:
            case "intent_unclear":
                return ok(f"unclear: {args.get('reason', '')}")

            case "current_datetime":
                return ok(datetime.now().strftime("%A %d %B %Y at %H:%M"))
            case "battery_status":
                return ok("87% charged, on battery")
            case "disk_free":
                return ok("341Gi free of 926Gi")
            case "top_processes":
                return ok("PID  %CPU COMM\n501 62.1 Google Chrome\n802 11.4 Spotlight")
            case "memory_pressure":
                return ok("free 335M, compressed 9G, swap used 1024M")
            case "wifi_status":
                return ok("Current Wi-Fi Network: Home")

            case "set_volume":
                s["volume"] = int(args.get("level", 50))
                return ok(f"volume {s['volume']}")
            case "mute_audio":
                s["muted"] = str(args.get("state", "")).lower() in ("on", "true", "mute")
                return ok("muted" if s["muted"] else "unmuted")
            case "set_dark_mode":
                s["dark_mode"] = str(args.get("state", "")).lower() in ("on", "true", "dark")
                return ok(f"dark mode {s['dark_mode']}")
            case "lock_screen":
                s["locked"] = True
                return ok("locked")

            case "list_events":
                same = [e for e in s["events"]]
                return ok("\n".join(f"{e['title']} at {e['start']}" for e in same) or "no events")
            case "next_event":
                return ok(s["events"][0]["title"] if s["events"] else "nothing scheduled")
            case "create_event":
                s["events"].append({"title": args.get("title", ""),
                                    "start": args.get("start", "")})
                return ok("created")
            case "delete_event":
                before = len(s["events"])
                s["events"] = [e for e in s["events"]
                               if args.get("title", "") not in e["title"]]
                return ok(f"deleted {before - len(s['events'])}")

            case "send_email":
                s["sent"].append({"to": args.get("to", ""),
                                  "subject": args.get("subject", ""),
                                  "body": args.get("body", "")})
                return ok("sent")
            case "unread_count":
                return ok("3")
            case "list_recent_mail":
                return ok("daisy@example.com — Agenda for Monday\nbank@example.com — Statement")
            case "search_mail":
                return ok("daisy@example.com — Agenda for Monday")

            case "create_reminder":
                s["reminders"].append({"title": args.get("title", ""),
                                       "due": args.get("due", ""), "completed": False})
                return ok("created")
            case "list_reminders":
                out = [r["title"] for r in s["reminders"] if not r["completed"]]
                return ok("\n".join(out) or "nothing outstanding")
            case "complete_reminder":
                for r in s["reminders"]:
                    if args.get("title", "") in r["title"]:
                        r["completed"] = True
                        return ok("completed")
                return ok("no such reminder")

            case "create_note":
                s["notes"].append({"title": args.get("title", ""),
                                   "body": args.get("body", "")})
                return ok("created")
            case "search_notes":
                q = args.get("query", "").lower()
                hits = [n["title"] for n in s["notes"] if q in n["title"].lower()]
                return ok("\n".join(hits) or "no matching notes")
            case "read_note":
                q = args.get("title", "").lower()
                for n in s["notes"]:
                    if q in n["title"].lower():
                        return ok(n["body"])
                return ok("no such note")

            case "find_file":
                q = args.get("name", "").replace("*", "").lstrip(".").lower()
                hits = [f for f in FILES if q in f.lower()]
                return ok("\n".join(hits) or "no matches")
            case "open_file":
                return ok("opened")
            case "recent_files":
                return ok("\n".join(FILES[:2]))
            case "large_files":
                return ok("1.4G\t/Users/you/Downloads/holiday.mov")

            case "move_file":
                s["moved"].append({"path": args.get("path", ""), "dest": args.get("dest", "")})
                return ok("moved")
            case "trash_file":
                s["trashed"].append(args.get("path", ""))
                return ok("trashed")
            case "empty_trash":
                s["trash_emptied"] = True
                return ok("emptied")

            case _:
                return {"ok": False, "error": f"unknown tool: {name}"}

    def called(self, name: str) -> bool:
        return any(c[0] == name for c in self.calls)

    def last_args(self, name: str) -> dict | None:
        for n, a in reversed(self.calls):
            if n == name:
                return a
        return None
