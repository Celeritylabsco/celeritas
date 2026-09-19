#!/usr/bin/env python3
"""Photograph each window of the app, one at a time, on its own.

    python3 app/Scripts/make-shots.py

Every picture in the readme and the setup guide comes from here. The app is
launched once per state with `--demo <state>`, which opens one window filled
with made-up data, and `screencapture -l` takes that window alone.

Two things this is careful about.

**Nothing behind the window is captured.** The first attempt screenshotted the
whole screen and caught a desktop full of somebody's messages, on its way to a
public repository. `-l <window id>` captures the window and nothing else.

**Nothing real is in the pictures.** The state comes from Shots.swift, where
every price, process and key is invented. Taking the same shot in a year gives
the same image, so the readme does not quietly change when the market does.

Needs pyobjc-framework-Quartz, and Screen Recording permission for whatever
runs it, which macOS asks for once.
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import Quartz

HERE = Path(__file__).resolve().parent
APP = HERE.parent / "build" / "Celeritas.app" / "Contents" / "MacOS" / "Celeritas"
OUT = HERE.parent.parent / "docs" / "media"

# The state, and the file it becomes. Ordered the way the readme reads.
SHOTS = [
    ("empty", "01-launcher"),
    ("coin", "02-coin"),
    ("share", "03-share"),
    ("currency", "04-currency"),
    ("units", "05-units"),
    ("maths", "06-maths"),
    ("convert", "07-convert"),
    ("token", "08-token"),
    ("emoji", "09-emoji"),
    ("apps", "10-apps"),
    ("machine", "11-machine"),
    ("calendar", "12-calendar"),
    ("answer", "14-answer"),
    ("onboarding", "15-first-run"),
    ("onboarding-key", "16-gateway-key"),
    ("settings-model", "17-settings-model"),
    ("settings-launcher", "18-settings-launcher"),
]


def windows() -> list[dict]:
    listing = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    return [w for w in listing
            if "Celeritas" in str(w.get("kCGWindowOwnerName", ""))
            # Skip the shadow-only and zero-size helper layers AppKit keeps.
            and w.get("kCGWindowBounds", {}).get("Width", 0) > 200]


def capture(state: str, name: str) -> bool:
    subprocess.run(["pkill", "-x", "Celeritas"], capture_output=True)
    time.sleep(1.0)
    process = subprocess.Popen([str(APP), "--demo", state],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    found = []
    for _ in range(40):
        time.sleep(0.25)
        found = windows()
        if found:
            break
    if not found:
        print(f"  {name}: no window appeared")
        process.terminate()
        return False

    # The biggest one, so a stray tooltip or shadow layer cannot win.
    window = max(found, key=lambda w: w["kCGWindowBounds"]["Width"]
                 * w["kCGWindowBounds"]["Height"])
    # A beat for the window to finish drawing, or the shot catches it mid fade.
    time.sleep(0.8)
    target = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l",
                    str(window["kCGWindowNumber"]), str(target)], check=False)
    process.terminate()
    process.wait(timeout=5)

    if not target.exists() or target.stat().st_size < 5000:
        print(f"  {name}: capture failed or came out empty")
        return False
    bounds = window["kCGWindowBounds"]
    print(f"  {target.name:<22} {int(bounds['Width'])}x{int(bounds['Height'])}"
          f"  {target.stat().st_size:,} bytes")
    return True


def main() -> int:
    if not APP.exists():
        print(f"no app at {APP}. Run ./Scripts/build-app.sh first.")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    ok = sum(capture(state, name) for state, name in SHOTS)
    subprocess.run(["pkill", "-x", "Celeritas"], capture_output=True)
    print(f"  {ok} of {len(SHOTS)} captured into {OUT}")
    return 0 if ok == len(SHOTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
