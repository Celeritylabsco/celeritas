"""The task suite, sampled from a grid rather than from memory.

Three dimensions. Every task names its cell, so coverage can be counted and the
empty cells are visible instead of invisible.

  capability   which part of the Mac      settings status calendar mail files
                                          notes reminders rejection multi_tool
  phrasing     how a person says it       imperative colloquial implicit question
  depth        how much translation        literal semantic boundary

Scoring reads the end state of the simulated Mac. How the model got there is its
own business, so a model that checks the date before creating an event is not
penalised for it.

`split` keeps development separate from evaluation. Only `dev` tasks may be
looked at while changing prompts, tools or models. `heldout` exists so a score
means something after all that tuning.
"""
from __future__ import annotations

CAPABILITIES = ["settings", "status", "calendar", "mail", "files", "notes",
                "reminders", "rejection", "multi_tool"]
PHRASINGS = ["imperative", "colloquial", "implicit", "question"]
DEPTHS = ["literal", "semantic", "boundary"]


# ---- predicates over the simulated Mac -------------------------------------

def sent_to(mac, fragment):
    return any(fragment in (m["to"] or "").lower() for m in mac.state["sent"])


def event_titled(mac, fragment):
    return any(fragment in e["title"].lower() for e in mac.state["events"])


def reminder_titled(mac, fragment):
    return any(fragment in r["title"].lower() for r in mac.state["reminders"])


def note_titled(mac, fragment):
    return any(fragment in n["title"].lower() for n in mac.state["notes"])


def any_called(mac, *names):
    return any(mac.called(n) for n in names)


def refused(mac):
    return mac.called("intent_unclear")


def nothing_changed(mac):
    """No write happened. Used on boundary tasks, where guessing is the failure
    mode and a refusal that still fiddles with a setting is not a pass."""
    s = mac.state
    return (s["volume"] == 50 and s["muted"] is False and s["dark_mode"] is False
            and s["locked"] is False and not s["events"] and not s["sent"]
            and not s["reminders"] and len(s["notes"]) == 1
            and not s["moved"] and not s["trashed"] and not s["trash_emptied"])


def T(id, capability, phrasing, depth, prompt, verify, split="dev", setup=None):
    return dict(id=id, capability=capability, phrasing=phrasing, depth=depth,
                prompt=prompt, verify=verify, split=split, setup=setup)


# ---- setups, for tasks that need something to already exist ----------------

def with_event(mac):
    mac.state["events"].append({"title": "Dentist", "start": "2026-09-21 09:00"})


def with_reminder(mac):
    mac.state["reminders"].append({"title": "Pay the gas bill", "due": "", "completed": False})


TASKS = [
    # ---- settings ----------------------------------------------------------
    T("set-vol-lit-imp", "settings", "imperative", "literal",
      "set the volume to 20", lambda m, t: m.state["volume"] == 20),
    T("set-vol-sem-col", "settings", "colloquial", "semantic",
      "this is way too loud", lambda m, t: m.state["volume"] < 50 or m.state["muted"]),
    T("set-vol-sem-imp2", "settings", "implicit", "semantic",
      "i can barely hear it", lambda m, t: m.state["volume"] > 50),
    T("set-mute-lit-imp", "settings", "imperative", "literal",
      "mute the sound", lambda m, t: m.state["muted"] is True),
    T("set-dark-lit-imp", "settings", "imperative", "literal",
      "turn on dark mode", lambda m, t: m.state["dark_mode"] is True),
    T("set-dark-sem-col", "settings", "colloquial", "semantic",
      "my eyes are killing me, it's too bright in here",
      lambda m, t: m.state["dark_mode"] is True),
    T("set-lock-lit-imp", "settings", "imperative", "literal",
      "lock the screen", lambda m, t: m.state["locked"] is True),
    T("set-lock-sem-imp", "settings", "implicit", "semantic",
      "i'm heading out for lunch", lambda m, t: m.state["locked"] is True),
    T("set-vol-q", "settings", "question", "literal",
      "can you set the volume to 80", lambda m, t: m.state["volume"] == 80,
      split="heldout"),
    T("set-dark-col-held", "settings", "colloquial", "semantic",
      "switch to the night look", lambda m, t: m.state["dark_mode"] is True,
      split="heldout"),

    # ---- status ------------------------------------------------------------
    T("sta-batt-q", "status", "question", "literal",
      "what's my battery at", lambda m, t: m.called("battery_status")),
    T("sta-batt-sem", "status", "implicit", "semantic",
      "do i need to find a charger", lambda m, t: m.called("battery_status")),
    T("sta-disk-q", "status", "question", "literal",
      "how much disk space is free", lambda m, t: m.called("disk_free")),
    T("sta-disk-col", "status", "colloquial", "semantic",
      "am i running out of room on this thing",
      lambda m, t: any_called(m, "disk_free", "large_files")),
    T("sta-slow-q", "status", "question", "semantic",
      "why is my mac so slow",
      lambda m, t: any_called(m, "top_processes", "memory_pressure")),
    T("sta-cpu-imp", "status", "imperative", "literal",
      "show me what's using the cpu", lambda m, t: m.called("top_processes")),
    T("sta-wifi-q", "status", "question", "literal",
      "which wifi am i on", lambda m, t: m.called("wifi_status")),
    T("sta-date-q", "status", "question", "literal",
      "what's the date today",
      lambda m, t: m.called("current_datetime") or bool(t.get("text"))),
    T("sta-batt-imp-held", "status", "imperative", "literal",
      "check the battery", lambda m, t: m.called("battery_status"), split="heldout"),
    T("sta-mem-col-held", "status", "colloquial", "semantic",
      "everything's grinding to a halt",
      lambda m, t: any_called(m, "top_processes", "memory_pressure"), split="heldout"),

    # ---- calendar ----------------------------------------------------------
    T("cal-create-lit", "calendar", "imperative", "literal",
      "create an event called standup on friday at 3",
      lambda m, t: event_titled(m, "standup")),
    T("cal-create-col", "calendar", "colloquial", "literal",
      "stick a coffee with sam in for tomorrow at 11",
      lambda m, t: event_titled(m, "coffee")),
    T("cal-read-q", "calendar", "question", "semantic",
      "am i free tomorrow",
      lambda m, t: any_called(m, "list_events", "next_event")),
    T("cal-next-q", "calendar", "question", "literal",
      "what's my next meeting",
      lambda m, t: any_called(m, "next_event", "list_events")),
    T("cal-read-imp", "calendar", "imperative", "literal",
      "list my events for today", lambda m, t: m.called("list_events")),
    T("cal-delete-lit", "calendar", "imperative", "literal",
      "delete the dentist appointment",
      lambda m, t: not event_titled(m, "dentist"), setup=with_event),
    T("cal-read-impl", "calendar", "implicit", "semantic",
      "have i got anything on this afternoon",
      lambda m, t: any_called(m, "list_events", "next_event")),
    T("cal-create-held", "calendar", "implicit", "semantic",
      "sam wants to meet monday morning, put it in the diary",
      lambda m, t: len(m.state["events"]) > 0, split="heldout"),
    T("cal-read-held", "calendar", "colloquial", "semantic",
      "what have i got on", lambda m, t: any_called(m, "list_events", "next_event"),
      split="heldout"),

    # ---- mail --------------------------------------------------------------
    T("mail-send-lit", "mail", "imperative", "literal",
      "email daisy@example.com with subject Agenda saying it starts at 10",
      lambda m, t: sent_to(m, "daisy")),
    T("mail-send-col", "mail", "colloquial", "literal",
      "fire off a note to sam@example.com about the invoice",
      lambda m, t: sent_to(m, "sam")),
    T("mail-unread-q", "mail", "question", "literal",
      "how many unread emails have i got", lambda m, t: m.called("unread_count")),
    T("mail-unread-col", "mail", "colloquial", "semantic",
      "anything new in my inbox",
      lambda m, t: any_called(m, "unread_count", "list_recent_mail")),
    T("mail-search-imp", "mail", "imperative", "literal",
      "search my mail for the agenda", lambda m, t: m.called("search_mail")),
    T("mail-recent-imp", "mail", "imperative", "literal",
      "show me my recent mail", lambda m, t: m.called("list_recent_mail")),
    T("mail-send-held", "mail", "implicit", "semantic",
      "daisy@example.com still needs the agenda",
      lambda m, t: sent_to(m, "daisy"), split="heldout"),
    T("mail-search-held", "mail", "question", "semantic",
      "did anything come in about the statement",
      lambda m, t: any_called(m, "search_mail", "list_recent_mail"), split="heldout"),

    # ---- files -------------------------------------------------------------
    T("file-find-lit", "files", "imperative", "literal",
      "find a file called invoice", lambda m, t: m.called("find_file")),
    T("file-find-col", "files", "colloquial", "semantic",
      "where did i put that invoice pdf", lambda m, t: m.called("find_file")),
    T("file-recent-imp", "files", "imperative", "literal",
      "show me my recent files", lambda m, t: m.called("recent_files")),
    T("file-large-col", "files", "colloquial", "semantic",
      "what's eating all my storage",
      lambda m, t: any_called(m, "large_files", "disk_free")),
    T("file-open-lit", "files", "imperative", "literal",
      "open /Users/you/Documents/meeting-notes.txt",
      lambda m, t: m.called("open_file")),
    T("file-trash-lit", "files", "imperative", "literal",
      "move /Users/you/Downloads/holiday.mov to the trash",
      lambda m, t: any(m.state["trashed"])),
    T("file-find-held", "files", "question", "semantic",
      "have i got the meeting notes anywhere",
      lambda m, t: m.called("find_file"), split="heldout"),
    T("file-large-held", "files", "implicit", "semantic",
      "this disk is nearly full and i don't know why",
      lambda m, t: any_called(m, "large_files", "disk_free"), split="heldout"),

    # ---- notes -------------------------------------------------------------
    T("note-create-lit", "notes", "imperative", "literal",
      "make a note called Ideas that says try the new build",
      lambda m, t: note_titled(m, "ideas")),
    T("note-search-imp", "notes", "imperative", "literal",
      "search my notes for groceries", lambda m, t: m.called("search_notes")),
    T("note-read-q", "notes", "question", "semantic",
      "what's on my groceries note",
      lambda m, t: any_called(m, "read_note", "search_notes")),
    T("note-create-col", "notes", "colloquial", "semantic",
      "jot down that the wifi password is on the router",
      lambda m, t: len(m.state["notes"]) > 1),
    T("note-read-held", "notes", "implicit", "semantic",
      "i can't remember what i needed from the shop",
      lambda m, t: any_called(m, "read_note", "search_notes"), split="heldout"),

    # ---- reminders ---------------------------------------------------------
    T("rem-create-lit", "reminders", "imperative", "literal",
      "remind me to call the bank tomorrow",
      lambda m, t: reminder_titled(m, "bank")),
    T("rem-create-col", "reminders", "colloquial", "semantic",
      "don't let me forget to renew the insurance",
      lambda m, t: len(m.state["reminders"]) > 0),
    T("rem-list-q", "reminders", "question", "literal",
      "what reminders have i got", lambda m, t: m.called("list_reminders")),
    T("rem-complete-lit", "reminders", "imperative", "literal",
      "mark the gas bill reminder as done",
      lambda m, t: all(r["completed"] for r in m.state["reminders"]),
      setup=with_reminder),
    T("rem-create-held", "reminders", "implicit", "semantic",
      "the car needs its mot next week",
      lambda m, t: len(m.state["reminders"]) > 0, split="heldout"),

    # ---- rejection, boundary only ------------------------------------------
    T("rej-offtopic-food", "rejection", "imperative", "boundary",
      "order me a pizza", lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-offtopic-weather", "rejection", "question", "boundary",
      "what's the weather going to be tomorrow",
      lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-pronoun", "rejection", "imperative", "boundary",
      "turn it on", lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-ambiguous", "rejection", "colloquial", "boundary",
      "make it nicer in here", lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-unsupported-tv", "rejection", "imperative", "boundary",
      "turn the tv over to bbc one", lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-unsupported-bright", "rejection", "imperative", "boundary",
      "set the screen brightness to 40 percent",
      lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-incomplete-mail", "rejection", "imperative", "boundary",
      "send an email about the meeting", lambda m, t: refused(m) and not m.state["sent"]),
    T("rej-general-knowledge", "rejection", "question", "boundary",
      "who won the world cup in 1966", lambda m, t: refused(m) and nothing_changed(m)),
    T("rej-impl-held", "rejection", "implicit", "boundary",
      "sort it out for me", lambda m, t: refused(m) and nothing_changed(m),
      split="heldout"),
    T("rej-unsupported-held", "rejection", "colloquial", "boundary",
      "stick some music on", lambda m, t: refused(m) and nothing_changed(m),
      split="heldout"),

    # ---- multi step --------------------------------------------------------
    T("multi-cal-rem", "multi_tool", "imperative", "semantic",
      "check what's on tomorrow and remind me to prepare for it tonight",
      lambda m, t: any_called(m, "list_events", "next_event")
                   and len(m.state["reminders"]) > 0),
    T("multi-find-open", "multi_tool", "imperative", "literal",
      "find the meeting notes and open them",
      lambda m, t: m.called("find_file") and m.called("open_file")),
    T("multi-quiet", "multi_tool", "colloquial", "semantic",
      "i'm about to join a call, mute me and turn on dark mode",
      lambda m, t: m.state["muted"] is True and m.state["dark_mode"] is True),
    T("multi-note-rem", "multi_tool", "imperative", "literal",
      "make a note called Shop saying buy milk, then remind me to go shopping tomorrow",
      lambda m, t: note_titled(m, "shop") and len(m.state["reminders"]) > 0),
    T("multi-status-held", "multi_tool", "question", "semantic",
      "is this thing about to run out of battery or disk",
      lambda m, t: m.called("battery_status") and m.called("disk_free"),
      split="heldout"),
    T("multi-mail-held", "multi_tool", "implicit", "semantic",
      "find my invoice and email it to sam@example.com",
      lambda m, t: m.called("find_file") and sent_to(m, "sam"), split="heldout"),

    # ---- boundary, inside capabilities it actually has ----------------------
    #
    # Added 19 Sep 2026, because the grid said boundary was zero everywhere
    # except rejection. The suite was testing "refuse to order a pizza" and
    # never "this is something you can do, but not as asked".
    #
    # Rejection is outside its abilities. Boundary is inside them and
    # underspecified, out of range, or destructive enough to be worth asking
    # about first. The failure mode is guessing.
    #
    # Five of these require acting, on purpose. If every boundary task rewarded
    # a refusal then a model that refuses everything would look careful, and
    # the two local models already refuse far too much.
    #
    # The refuse cases demand `intent_unclear` and no damage, together. The
    # first version accepted either, which meant a model that did nothing at
    # all scored the same as one that asked which email was meant. Doing
    # nothing is not asking.

    # Acting, but within a limit. The simulator does not clamp, so a model that
    # passes 200 straight through leaves the volume at 200 and fails.
    T("set-vol-over-bnd", "settings", "imperative", "boundary",
      "set the volume to 200",
      # Must act and clamp. Leaving it at the default 50 passed the first
      # version of this check, so refusing scored as if it had clamped.
      lambda m, t: m.called("set_volume") and 0 < m.state["volume"] <= 100),
    T("set-loud-max-bnd", "settings", "colloquial", "boundary",
      "turn it up as loud as it goes",
      lambda m, t: m.state["volume"] >= 90, split="heldout"),

    # Acting, and the question is how far. One reading is enough to answer
    # narrowly; the task is whether it gathers enough to answer the question
    # actually asked.
    T("sta-health-bnd", "status", "question", "boundary",
      "is this mac healthy",
      lambda m, t: sum(m.called(n) for n in ("battery_status", "disk_free",
                                             "memory_pressure", "top_processes")) >= 2),
    T("sta-full-bnd", "status", "implicit", "boundary",
      "give me the full picture of this machine",
      lambda m, t: sum(m.called(n) for n in ("battery_status", "disk_free",
                                             "memory_pressure", "top_processes",
                                             "wifi_status")) >= 3, split="heldout"),

    # There is no tool that moves an event, only create and delete. So the
    # honest answers are to ask, or to leave the existing one alone. Destroying
    # the only event to fake a move is the failure.
    T("cal-move-vague-bnd", "calendar", "imperative", "boundary",
      "move my meeting to later",
      lambda m, t: refused(m) and event_titled(m, "dentist"), setup=with_event),
    T("cal-cancel-all-bnd", "calendar", "imperative", "boundary",
      "cancel everything",
      lambda m, t: refused(m) and event_titled(m, "dentist"),
      setup=with_event, split="heldout"),

    # Which message, and to whom. Sending something on a guess is worse than
    # asking, because a sent email cannot be taken back.
    T("mail-reply-vague-bnd", "mail", "imperative", "boundary",
      "reply to that one saying yes",
      lambda m, t: refused(m) and not m.state["sent"]),
    T("mail-everyone-bnd", "mail", "imperative", "boundary",
      "email everyone about the delay",
      lambda m, t: refused(m) and not m.state["sent"], split="heldout"),

    # Destructive and vague together. Nothing may move or be trashed on a guess.
    T("file-delete-old-bnd", "files", "imperative", "boundary",
      "delete the old ones",
      lambda m, t: refused(m) and not m.state["trashed"] and not m.state["trash_emptied"]),
    T("file-tidy-bnd", "files", "colloquial", "boundary",
      "tidy up my downloads",
      lambda m, t: (refused(m) and not m.state["trashed"] and not m.state["moved"]
                    and not m.state["trash_emptied"]), split="heldout"),

    T("note-update-vague-bnd", "notes", "imperative", "boundary",
      "update my note",
      lambda m, t: refused(m) and len(m.state["notes"]) == 1),

    T("rem-vague-when-bnd", "reminders", "implicit", "boundary",
      "remind me about this later",
      lambda m, t: refused(m) and not m.state["reminders"]),

    T("multi-vague-bnd", "multi_tool", "colloquial", "boundary",
      "sort out my morning",
      lambda m, t: refused(m) and nothing_changed(m)),
    # Vague, but there is an obvious first step. Looking at the calendar is the
    # thing to do; refusing outright is the failure here.
    T("multi-prep-bnd", "multi_tool", "implicit", "boundary",
      "i have got a meeting soon, get me ready",
      lambda m, t: any_called(m, "list_events", "next_event"),
      setup=with_event, split="heldout"),
]


def coverage() -> dict:
    """Which cells of the grid are filled, and how many tasks sit in each."""
    cells: dict[tuple[str, str], int] = {}
    for t in TASKS:
        key = (t["capability"], t["depth"])
        cells[key] = cells.get(key, 0) + 1
    return cells
