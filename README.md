# Celeritas

A launcher for the Mac. Press a key, type what you want, get an answer.

Most of what you type never reaches a model. Arithmetic, unit conversion,
currency, share and coin prices, emoji and app names are all answered on the
machine from a file, in under a millisecond, for nothing. A model is asked only
when the question needs one, and the row always says which model is about to
get it and what it will cost.

```
btc                 BTC  81,288.44 USD  +0.23%     Bitcoin, live 14:07
aapl                AAPL  336.13  -0.26%           Apple Inc., close 18 Sep
1 eth to sol        1 ETH  =  23.6044 SOL          live 14:07
0.5 btc in usd      0.5 BTC  =  40,644.22 USD      live 14:07
100 usd in eur      92.04 EUR                      rate from 19 Sep
orbio price         ORBIO  $0.0528  +8.6%          Orbio.so, $1.7m liquidity
20c                 68 °F
180 lb in kg        81.65 kg
5 * 12              60
fire                🔥 🚒 🧯 ❤️‍🔥
safari              Safari
am i free tomorrow  reads your calendar, asks the model
```

## What is here

```
app/         the launcher. SwiftPM, no Xcode project
bench/       the benchmark, its task suite and every run record
runtime/     the agent loop the benchmark drives
tools/       the 32 tool definitions the model is offered
```

## Running it

Swift 6.2 and macOS 26.

```sh
cd app
swift build
./Scripts/build-app.sh      # assembles Celeritas.app
open build/Celeritas.app
```

There is no signed download yet. The app is ad-hoc signed, so Gatekeeper will
refuse it on a machine that did not build it.

## Three places an answer can come from

Settings offers all three and prints what each one scored, because the
difference between them is real and hiding it would be the same overclaiming
this project spends its time avoiding.

- **Apple Intelligence.** On the machine, free, and the weakest of the three.
- **A local model**, downloaded and run through llama.cpp. Free, private, and
  much better than Apple Intelligence at choosing tools.
- **A gateway key.** Best results. The app ships pointed at one and you paste
  your own key.

## The benchmark

Picking the model meant measuring them, so `bench/` holds the suite, the
harness and every run record. Two suites:

**Tool choice.** 85 tasks on a simulated Mac, scored on the end state rather
than on what the model said it would do. Split into 55 tuned tasks and 22 held
out. Every model scores 5 to 23 points lower on the held-out ones, and the
ordering changes.

**Routing.** 52 cases measuring the launcher rather than a model: which of the
ten paths answers a query, and for the 23 with one right answer, whether the
answer is right. It found two bugs on its first run.

```sh
python3 bench/run.py --model <id> --split heldout
swift run RoutingBench --spec bench/routing.json --out bench/results
```

The write-up is at <https://celeritylabs.co/notes/tool-choice> and the data is
at <https://huggingface.co/datasets/celerity-labs/celeritybench-tool-choice>.

## Licence

MIT for the code. The dataset is CC BY 4.0, so if you publish a number from it,
say which split it came from.

Built by [Celerity Labs](https://celeritylabs.co).
