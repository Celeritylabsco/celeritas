---
license: cc-by-4.0
task_categories:
  - text-generation
tags:
  - tool-use
  - function-calling
  - agents
  - small-language-models
  - macos
size_categories:
  - 1K<n<10K
configs:
  - config_name: tasks
    data_files: data/tasks.jsonl
  - config_name: runs
    data_files: data/runs.jsonl
  - config_name: results
    data_files: data/results.jsonl
  - config_name: routing_cases
    data_files: data/routing_cases.jsonl
  - config_name: routing_runs
    data_files: data/routing_runs.jsonl
  - config_name: routing_results
    data_files: data/routing_results.jsonl
---

# Which small model should run a Mac launcher

Celeritas is a Spotlight-style launcher that turns what somebody types into tool
calls on their own machine. Picking the model to put behind it meant measuring
them, and the numbers were going on a public page, so the runs behind them are
here.

The question is narrow on purpose: **for an agent with about thirty tools on a
desktop, which model picks the right one?** Not reasoning, not code, not
knowledge. Tool choice, on short everyday phrasing.

## What is in here

| file | rows | what it is |
|---|---|---|
| `data/tasks.jsonl` | 85 | the suite, one row per task |
| `data/runs.jsonl` | 45 | one row per model run, 15 models |
| `data/results.jsonl` | 1,457 | every scored attempt |
| `data/routing_cases.jsonl` | 52 | the launcher suite, described below |
| `data/routing_runs.jsonl` | per run | routing and correctness totals |
| `data/routing_results.jsonl` | 52 per run | every routed query |

Start with `runs.jsonl` for the leaderboard and `results.jsonl` for anything
per task. Join them on `run_id`.

```python
from datasets import load_dataset
runs = load_dataset("<this dataset>", "runs")["train"]
fresh = [r for r in runs if r["split"] == "heldout" and r["task_count"] == 22]
```

**Filter on `split` before comparing anything.** `dev` is the 55 tasks the
prompts and tools were tuned against, `heldout` is the 22 that were kept back
and run once at the end. Twelve older runs predate the split and carry `null`.
Every model scores 5 to 23 points lower on `heldout`, and the ordering changes:
the model this launcher shipped with went from first to eighth.

## How tasks are built

Each task names its cell in a grid, so coverage can be counted and the holes are
visible instead of invisible.

```
capability   settings status calendar mail files notes reminders rejection multi_tool
phrasing     imperative colloquial implicit question
depth        literal semantic boundary
```

Depth is the one that matters:

```
literal    "set the volume to 20"     says exactly what to do
semantic   "this is way too loud"     means turn it down, never says so
boundary   the hard edge              should it act at all, and how far
```

Scoring reads the **end state of a simulated Mac**, not the model's words. How a
model got there is its own business, so one that checks the date before making
an event is not marked down for it. The simulator and the scoring predicates are
in the repository beside this file; a scoring rule written out as prose is a
rule nobody can run.

`rejection` tasks have no correct tool call. The only pass is asking for more,
and eight of the ten are things the launcher genuinely cannot do. Local models
are much worse at this than at anything else in the suite, which is the most
useful single thing in these results.

`boundary` tasks inside real capabilities were added on 19 Sep 2026, because the
grid showed boundary was zero everywhere except rejection. Five of them require
**acting**, deliberately: if every boundary task rewarded a refusal, a model that
refuses everything would look careful.

## The second suite: routing

The model suite measures a model. The routing suite measures the launcher.

Almost nothing typed into Celeritas reaches a model. Arithmetic, unit and
currency conversion, share and coin prices, emoji and app names are answered on
the machine, and our own code decides which path handles a query. That decision
is invisible until it is wrong, and it was wrong twice in one day:

- `am i free today` was taken by the clock, because the trigger word "today"
  was at the end of the sentence.
- `1 eth to sol` was handed to a model, which answered **66** from prices it half
  remembered. The real answer was **23.6**, and both numbers were already cached
  on the machine.

Each case says which section must appear, which must not, and for the 23 cases
with a single right answer, what the answer must contain. Building it found a
real bug: the currency converter's own documentation had promised `20 chf jpy`
since the file was written and the code never implemented it.

## Limitations, and they are real

- **One trial per model at temperature zero.** No error bars.
- **Both splits are too small to rank finely.** One task is 1.8 points on the
  55 tuned tasks and 4.5 points on the 22 held out, and on each split several
  models land within one task of each other.
- **Latency is not comparable for most models.** Nine of the leaderboard runs
  were executed concurrently and carry `timings_valid: false`. Accuracy is
  unaffected by concurrency; seconds are not. Filter on that field before
  comparing any timing.
- **No frontier models were tested.** The dearest thing here is a small
  commercial model. This suite exists to choose something cheap enough to sit
  behind every keystroke, so reading it as "cheap beats expensive" is wrong.
  Expensive was never in the room.
- **Tied to one tool set.** Thirty two tools for one macOS launcher. A model that
  does well here may not transfer.
- **Nothing is filtered on the way out.** Smoke runs on a 13 task subset and
  runs from before the split existed are both included, labelled. A dataset that
  quietly drops its own unflattering rows is worse than no dataset.

## Reproducing

```sh
python3 bench/run.py --model openai/gpt-oss-20b --split dev
python3 bench/run.py --model openai/gpt-oss-20b --split heldout
swift run RoutingBench --spec bench/routing.json --out bench/results
python3 bench/to-dataset.py --out ../celerity-dataset
```

`dev` is the split you may look at while changing prompts, tools or models.
`heldout` exists so a score still means something after all that tuning.

## Licence and citation

CC BY 4.0. Use it for anything, including commercially, including building a
competing launcher. The one condition is attribution, so here is a form of it
that satisfies the licence and saves you writing one:

```bibtex
@misc{celeritybench2026,
  title  = {CelerityBench: tool choice on a Mac},
  author = {{Celerity Labs}},
  year   = {2026},
  url    = {https://celeritylabs.co/notes/tool-choice},
  note   = {Tool-use and routing benchmark for small models driving a desktop launcher}
}
```

If you publish a number from here, say which split it came from. `dev` and
`heldout` differ by 5 to 23 points per model and quoting the wrong one is the
mistake this dataset exists to make visible.

## Where the write-up is

The note explaining what this found, and why every model fell on the held-out
split, is at <https://celeritylabs.co/notes/tool-choice>. This card is the
reference; that is the argument.

Published by Celerity Labs.
