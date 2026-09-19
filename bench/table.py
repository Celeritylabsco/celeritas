#!/usr/bin/env python3
"""Print the leaderboard from the run records.

Only runs that match on task count, split and tool_choice belong in one table.
Mixing conditions is how a leaderboard becomes incomparable, so runs are grouped
by condition and anything odd is listed separately rather than quietly averaged.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPS = ["status", "settings", "calendar", "mail", "files", "notes",
        "reminders", "multi_tool", "rejection"]


def load(results: str):
    runs = []
    for f in glob.glob(os.path.join(results, "*.json")):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        d["_file"] = os.path.basename(f)
        runs.append(d)
    return runs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(HERE / "results"))
    ap.add_argument("--tasks", type=int, default=55)
    ap.add_argument("--split", default="dev")
    ap.add_argument("--tool-choice", default="auto")
    ap.add_argument("--caps", action="store_true", help="show the capability breakdown")
    args = ap.parse_args()

    runs = load(args.results)
    keep = [r for r in runs
            if r.get("task_count") == args.tasks
            and r.get("split") == args.split
            and (r.get("tool_choice") or "auto") == args.tool_choice]

    # Keep the newest run per model, so re-runs supersede rather than duplicate.
    latest: dict[str, dict] = {}
    for r in sorted(keep, key=lambda r: r["started_utc"]):
        latest[r["model"]] = r

    rows = sorted(latest.values(), key=lambda r: (-(r.get("accuracy") or 0)))
    if not rows:
        print("no runs matched that condition")
        return

    print(f"{args.tasks} tasks, split={args.split}, tool_choice={args.tool_choice}\n")
    head = f"{'model':<34}{'score':>8}{'acc':>8}{'cost':>10}{'mean s':>9}  timings"
    print(head)
    print("-" * len(head))
    for r in rows:
        timings = "ok" if r.get("timings_valid", True) else "contended"
        cost = f"${r['total_cost']:.4f}" if r.get("total_cost") else "free"
        print(f"{r['model'][:33]:<34}{r['passed']:>4}/{r['total']:<3}"
              f"{(r.get('accuracy') or 0)*100:>7.1f}%{cost:>10}"
              f"{(r.get('mean_seconds') or 0):>9.2f}  {timings}")

    if args.caps:
        print()
        print(f"{'model':<34}" + "".join(f"{c[:6]:>8}" for c in CAPS))
        for r in rows:
            bc = r.get("by_capability", {})
            print(f"{r['model'][:33]:<34}" + "".join(f"{bc.get(c,'-'):>8}" for c in CAPS))

    other = [r for r in runs if r not in keep]
    if other:
        print(f"\n{len(other)} run(s) outside this condition, not shown:")
        seen = set()
        for r in other:
            k = (r["model"], r.get("task_count"), r.get("split"), r.get("tool_choice"))
            if k in seen:
                continue
            seen.add(k)
            print(f"  {r['model'][:36]:<38} tasks={r.get('task_count')} "
                  f"split={r.get('split','?')} tc={r.get('tool_choice','?')}")


if __name__ == "__main__":
    main()
