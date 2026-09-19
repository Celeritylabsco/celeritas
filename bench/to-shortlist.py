#!/usr/bin/env python3
"""Pick the models the app offers, from the held-out split.

    python3 bench/to-shortlist.py

The file this writes decides which model Celeritas uses out of the box, and it
used to be maintained by hand from the development numbers. Both of those were
wrong.

Hand-maintained, because a number typed once disagrees with its own runs inside
a week. And from the development split, because that is the split the prompts
and tools were tuned against. When the held-out split was finally run on 19 Sep
2026 every model scored 5 to 23 points lower and the order changed: the model
the app shipped with went from first to eighth.

So the basis is held-out, and dev is carried alongside for contrast rather than
for ranking.
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
OUT = HERE / "shortlist.json"
APP_COPY = HERE.parent / "app/Sources/CeleritasKit/Resources/shortlist.json"

HELDOUT_TASKS = 22
# How many the app offers. More than about six is a wall of names in a settings
# pane, and everything below the cut is in the dataset anyway.
KEEP = 6


def runs() -> list[dict]:
    out = []
    for path in RESULTS.glob("*.json"):
        if path.name.endswith("_routing.json"):
            continue
        out.append(json.loads(path.read_text()))
    return out


def latest(all_runs: list[dict], model: str, split: str, count: int | None = None):
    matching = [r for r in all_runs if r.get("model") == model and r.get("split") == split
                and (count is None or r.get("task_count") == count)]
    return max(matching, key=lambda r: r.get("started_utc") or "") if matching else None


def main() -> int:
    all_runs = runs()
    models = sorted({r["model"] for r in all_runs
                     if r.get("split") == "heldout" and r.get("task_count") == HELDOUT_TASKS})

    scored = []
    for model in models:
        held = latest(all_runs, model, "heldout", HELDOUT_TASKS)
        dev = latest(all_runs, model, "dev", 63) or latest(all_runs, model, "dev", 55)
        if not held:
            continue
        # Cost and latency come from the development run, which covers more
        # tasks and gives a steadier figure. `cost_tasks` says how many tasks
        # that money bought, because dividing it by the held-out count would
        # overstate the price of a question by about two and a half times.
        basis = dev or held
        cost = basis.get("total_cost") or 0
        scored.append({
            "id": model,
            "score": f"{held['passed']}/{held['total']}",
            "tuned_score": f"{dev['passed']}/{dev['total']}" if dev else None,
            "cost_per_run": round(cost, 5),
            "cost_tasks": basis.get("task_count"),
            "median_seconds": basis.get("median_seconds"),
            "local": cost == 0,
        })

    # Held-out accuracy first, then the cheaper one. Ties on 22 tasks are common
    # and cost is the only tie-break that cannot be argued with.
    scored.sort(key=lambda m: (-eval_score(m["score"]), m["cost_per_run"]))
    keep, dropped = scored[:KEEP], scored[KEEP:]

    payload = {
        "decided": date.today().isoformat(),
        "basis": f"{HELDOUT_TASKS} held-out tasks, tool_choice=auto, one trial, temperature 0",
        "tasks": HELDOUT_TASKS,
        "tie_break": "cost per run, ascending, applied to models level on score",
        "caveats": [
            f"Held-out, so no prompt or tool was tuned against these. Every model "
            f"scored 5 to 23 points lower here than on the development split.",
            f"{HELDOUT_TASKS} tasks means one task is "
            f"{100 / HELDOUT_TASKS:.1f} points. Models within one task of each "
            f"other are not ranked by this.",
            "One trial per model at temperature zero. No error bars.",
            "No frontier models were tested. The suite exists to choose something "
            "cheap enough to sit behind every keystroke.",
            "Cost and latency are carried over from the development run, which "
            "covers more tasks and so gives a steadier figure.",
        ],
        "models": [{k: v for k, v in m.items() if v is not None} for m in keep],
        "dropped": [{"id": m["id"], "score": m["score"],
                     "why": f"{m['score']} held out, below the six kept"} for m in dropped],
    }

    body = json.dumps(payload, indent=1) + "\n"
    OUT.write_text(body)
    APP_COPY.write_text(body)
    print(f"  {len(models)} models with a held-out score, keeping {len(keep)}")
    for m in keep:
        tuned = m.get("tuned_score") or "-"
        print(f"    {m['id']:<30} {m['score']:>6} held out   {tuned:>6} tuned")
    print(f"  default becomes {keep[0]['id']}")
    print(f"  written {OUT} and the app copy")
    return 0


def eval_score(score: str) -> float:
    a, b = score.split("/")
    return float(a) / float(b)


if __name__ == "__main__":
    raise SystemExit(main())
