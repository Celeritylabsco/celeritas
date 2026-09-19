#!/usr/bin/env python3
"""Turn the run records into a dataset anyone can check the numbers against.

    python3 bench/to-dataset.py --out ../celerity-dataset

The site publishes a leaderboard. A leaderboard with nothing behind it is a
claim, so this writes out the task suite, every per-task result and a summary,
in the shape Hugging Face reads without being told anything.

Nothing is filtered on the way out. Runs on the small 13 task smoke split and
runs from before the split was introduced are both here, labelled, because a
dataset that quietly drops its own unflattering rows is worse than no dataset.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import tasks as suite                                             # noqa: E402

RESULTS = HERE / "results"


# Columns that are numbers with a decimal point, even when the value happens to
# land on a whole one. A local model costs exactly 0 and a perfect routing run
# scores exactly 1, and both serialise as integers. Arrow then sees one column
# holding ints and floats, and the viewer can render the minority as null.
FLOATS = {
    "accuracy", "routing_accuracy", "value_accuracy", "total_cost", "cost",
    "mean_seconds", "median_seconds", "wall_seconds", "seconds",
}


def settle(row: dict) -> dict:
    """One type per column, whatever the value happens to be."""
    out = {}
    for key, value in row.items():
        if key in FLOATS and isinstance(value, (int, float)) and not isinstance(value, bool):
            out[key] = float(value)
        else:
            out[key] = value
    return out


def write(path: Path, rows: list[dict]) -> None:
    rows = [settle(r) for r in rows]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"  {path.name}: {len(rows)} rows, {path.stat().st_size:,} bytes")


def task_rows() -> list[dict]:
    out = []
    for task in suite.TASKS:
        out.append({
            "id": task["id"],
            "prompt": task["prompt"],
            "capability": task["capability"],
            "phrasing": task["phrasing"],
            "depth": task["depth"],
            "split": task.get("split"),
            # `verify` is a Python predicate over the simulated Mac and cannot
            # be serialised, and `setup` seeds that Mac before the task runs.
            # Both are in tasks.py beside this file, which is the only honest
            # place for them: a scoring rule written out as prose is a rule
            # nobody can run.
            "has_setup": task.get("setup") is not None,
        })
    return out


def routing_rows() -> tuple[list[dict], list[dict]]:
    """The launcher suite, which measures our own code rather than a model."""
    detail, summary = [], []
    for path in sorted(RESULTS.glob("*_routing.json")):
        record = json.loads(path.read_text())
        run_id = path.stem
        summary.append({
            "run_id": run_id,
            "suite": "routing",
            "started_utc": record.get("started_utc"),
            "cases": record.get("cases"),
            "routed": record.get("routed"),
            "routing_accuracy": record.get("routing_accuracy"),
            "value_checked": record.get("value_checked"),
            "value_correct": record.get("value_correct"),
            "value_accuracy": record.get("value_accuracy"),
            # Which tables were on disk. A missing one fails every case that
            # needs it, and that is not a routing fault.
            "tables": record.get("tables"),
        })
        for row in record.get("rows") or []:
            detail.append({"run_id": run_id, **row})
    return detail, summary


def run_rows() -> tuple[list[dict], list[dict]]:
    """Every per-task result, and one summary row per model run."""
    detail, summary = [], []
    for path in sorted(RESULTS.glob("*.json")):
        if path.name.endswith("_routing.json"):
            continue
        record = json.loads(path.read_text())
        run_id = path.stem
        summary.append({
            "run_id": run_id,
            "model": record.get("model"),
            "base": record.get("base"),
            "split": record.get("split"),
            "prompt_variant": record.get("prompt_variant"),
            "tool_choice": record.get("tool_choice"),
            "max_turns": record.get("max_turns"),
            "trials": record.get("trials"),
            "task_count": record.get("task_count"),
            "passed": record.get("passed"),
            "total": record.get("total"),
            "accuracy": record.get("accuracy"),
            "mean_seconds": record.get("mean_seconds"),
            "median_seconds": record.get("median_seconds"),
            "wall_seconds": record.get("wall_seconds"),
            # False when the run was concurrent. Accuracy is unaffected by
            # concurrency, latency is not, and a contended timing published as
            # a clean one is a number people would compare.
            "timings_valid": record.get("timings_valid"),
            "parallel": record.get("parallel"),
            "total_cost": record.get("total_cost"),
            "started_utc": record.get("started_utc"),
            "by_capability": record.get("by_capability"),
        })
        for row in record.get("rows") or []:
            detail.append({
                "run_id": run_id,
                "model": record.get("model"),
                "split": record.get("split"),
                "timings_valid": record.get("timings_valid"),
                **row,
            })
    return detail, summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out).expanduser().resolve()

    detail, summary = run_rows()
    route_detail, route_summary = routing_rows()
    write(out / "data" / "tasks.jsonl", task_rows())
    write(out / "data" / "runs.jsonl", summary)
    write(out / "data" / "results.jsonl", detail)
    write(out / "data" / "routing_cases.jsonl", json.loads(
        (HERE / "routing.json").read_text())["cases"])
    if route_summary:
        write(out / "data" / "routing_runs.jsonl", route_summary)
        write(out / "data" / "routing_results.jsonl", route_detail)

    models = sorted({row["model"] for row in summary if row.get("model")})
    splits = sorted({str(row.get("split")) for row in summary})
    print(f"  {len(models)} models, {len(summary)} model runs, {len(detail)} scored attempts")
    print(f"  splits present: {splits}")
    print(f"  {len(route_summary)} routing runs, {len(route_detail)} routing cases")
    detail = detail + route_detail

    for row in detail:
        for secret in ("sk-or", "apikey", "api_key", "bearer"):
            if secret in json.dumps(row).lower():
                print(f"  REFUSING: {secret} appears in {row.get('run_id')}")
                return 1
    print("  no credential in any row")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
