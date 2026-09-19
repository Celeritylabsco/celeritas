#!/usr/bin/env python3
"""Run the benchmark against one model and write the record to a file.

    CELERITY_BASE=http://127.0.0.1:8138/v1 CELERITY_KEY=none \
      python3 bench/run.py --model LFM2.5-1.2B --repeat 1

Machine memory and swap are recorded beside the timings. Liquid's own note says
their latency numbers were wrong at least once because the machine was swapping
and nobody wrote it down.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "runtime"))

from agent import loop          # noqa: E402
from executor import schema     # noqa: E402
from fake import FakeMac        # noqa: E402
from tasks import TASKS         # noqa: E402


def machine_state() -> dict:
    def sh(*cmd):
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    vm = sh("vm_stat")
    page = int(sh("pagesize") or 16384)

    def pages(label):
        for line in vm.splitlines():
            if label in line:
                return int("".join(c for c in line.split(":")[1] if c.isdigit()))
        return 0

    return {
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "free_mb": pages("Pages free") * page // 1048576,
        "compressed_mb": pages("Pages occupied by compressor") * page // 1048576,
        "swap": sh("sysctl", "-n", "vm.swapusage"),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--max-turns", type=int, default=5)
    ap.add_argument("--out", default=str(HERE / "results"))
    ap.add_argument("--split", default="dev", choices=["dev", "heldout", "all"],
                    help="heldout is for final numbers only, never for tuning")
    ap.add_argument("--depth", default=None, choices=["literal", "semantic", "boundary"],
                    help="restrict to one depth, for checking a new batch of tasks")
    ap.add_argument("--only", default=None,
                    help="restrict to one capability")
    args = ap.parse_args()

    tasks = [t for t in TASKS
             if args.split == "all" or t["split"] == args.split]
    if args.only:
        tasks = [t for t in tasks if t["capability"] == args.only]
    if args.depth:
        tasks = [t for t in tasks if t["depth"] == args.depth]
    if not tasks:
        print("no tasks matched")
        raise SystemExit(1)

    tools = schema()
    before = machine_state()
    started = datetime.now(timezone.utc)
    t0 = time.time()

    rows = []
    for trial in range(args.repeat):
        for task in tasks:
            mac = FakeMac()
            if task.get("setup"):
                task["setup"](mac)
            trace = loop(task["prompt"], args.model, execute=mac.execute,
                         tools=tools, max_turns=args.max_turns,
                         confirm_destructive=True)
            try:
                passed = bool(task["verify"](mac, trace))
            except Exception as e:                            # noqa: BLE001
                passed = False
                trace["verify_error"] = f"{type(e).__name__}: {e}"
            if trace.get("transport"):
                print(f"\n  TRANSPORT FAILURE on {task['id']}, run abandoned")
                print(f"  {str(trace.get('error'))[:200]}")
                print("  a network failure is not a model result. nothing written.")
                raise SystemExit(2)
            rows.append({
                "trial": trial, "id": task["id"],
                "capability": task["capability"], "phrasing": task["phrasing"],
                "depth": task["depth"], "prompt": task["prompt"],
                "passed": passed,
                "calls": [c["tool"] for c in trace.get("calls", [])],
                "turns": trace.get("turns"), "stopped": trace.get("stopped"),
                "seconds": trace.get("seconds"), "cost": trace.get("cost"),
                "error": trace.get("error"),
                "retries": sum(1 for c in trace.get("calls", [])),
            })
            mark = "OK " if passed else "   "
            chain = " -> ".join(r for r in rows[-1]["calls"]) or "(none)"
            print(f"{mark} {task['id']:<14} {rows[-1]['seconds'] or 0:5.2f}s  {chain[:64]}")

    n = len(rows)
    passed = sum(r["passed"] for r in rows)
    times = [r["seconds"] or 0 for r in rows]
    cost = sum(r["cost"] or 0 for r in rows)

    by_cap: dict[str, list[bool]] = {}
    for r in rows:
        by_cap.setdefault(r["capability"], []).append(r["passed"])

    record = {
        "model": args.model,
        "started_utc": started.isoformat(timespec="seconds"),
        "wall_seconds": round(time.time() - t0, 1),
        "base": os.environ.get("CELERITY_BASE", "(default)"),
        "prompt_variant": os.environ.get("CELERITY_PROMPT", ""),
        "tool_choice": os.environ.get("CELERITY_TOOL_CHOICE", "auto"),
        "parallel": bool(os.environ.get("CELERITY_PARALLEL")),
        "timings_valid": not os.environ.get("CELERITY_PARALLEL"),
        "task_count": len(tasks), "split": args.split, "trials": args.repeat,
        "passed": passed, "total": n,
        "accuracy": round(passed / n, 3) if n else None,
        "mean_seconds": round(statistics.mean(times), 2) if times else None,
        "median_seconds": round(statistics.median(times), 2) if times else None,
        "total_cost": round(cost, 6),
        "max_turns": args.max_turns,
        "by_capability": {k: f"{sum(v)}/{len(v)}" for k, v in sorted(by_cap.items())},
        "machine_before": before, "machine_after": machine_state(),
        "rows": rows,
    }

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stamp = started.strftime("%Y-%m-%dT%H-%M-%S")
    safe = args.model.replace("/", "_")
    tag = (os.environ.get("CELERITY_PROMPT", "") or "bare").replace(",", "+") + "_" + args.split
    safe = f"{safe}_{tag}"
    path = out / f"{stamp}_{safe}.json"
    path.write_text(json.dumps(record, indent=1) + "\n")

    print(f"\n  {args.model}")
    print(f"  accuracy   {passed}/{n}  ({record['accuracy']})")
    print(f"  mean       {record['mean_seconds']}s   median {record['median_seconds']}s")
    print(f"  cost       ${record['total_cost']}")
    print(f"  by capability  {record['by_capability']}")
    print(f"  machine    free {before['free_mb']}MB, {before['swap']}")
    print(f"  written    {path}")


if __name__ == "__main__":
    main()
