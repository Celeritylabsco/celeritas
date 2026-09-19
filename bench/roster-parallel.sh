#!/bin/bash
# Run the cloud roster concurrently with xargs, so every worker is a direct
# child of this script. Accuracy is unaffected by concurrency, latency is not:
# timings from a parallel run are contended and are flagged invalid in the
# record. Shortlisted models get a separate sequential pass for timing.
set -u
cd "$(dirname "$0")/.."
# The keys live in the labs repo, checked out beside this one. Set
# CELERITY_LABS if yours is somewhere else.
LABS="${CELERITY_LABS:-$PWD/../celerity-labs}"
[ -f "$LABS/.env" ] || { echo "no .env at $LABS, set CELERITY_LABS"; exit 1; }
set -a; . "$LABS/.env"; set +a
export CELERITY_BASE="$ORBIO_API_BASE" CELERITY_KEY="$ORBIO_OPENROUTER_KEY"
export CELERITY_PARALLEL=1

cat > /tmp/celerity-roster.txt <<'EOF'
google/gemini-2.5-flash-lite
google/gemini-3.1-flash-lite
qwen/qwen3.7-flash
deepseek/deepseek-v4-flash
openai/gpt-5-nano
openai/gpt-oss-20b
z-ai/glm-4.7-flash
z-ai/glm-5.3-flash
anthropic/claude-3-haiku
anthropic/claude-haiku-4.5
moonshotai/kimi-k2.5
mistralai/ministral-8b-2512
EOF

SPLIT="${1:-dev}"
# Twelve workers earned a 429 from Orbio on 19 Sep 2026: "too many requests a
# minute on this key". The harness abandoned every run rather than writing a
# partial one, which is right, but nothing came back. Three is under the limit.
WORKERS="${2:-3}"
export SPLIT
xargs -P "$WORKERS" -I{} sh -c 'python3 bench/run.py --model "{}" --split "$SPLIT" > "/tmp/bench-$(echo {} | tr / _).out" 2>&1' \
  < /tmp/celerity-roster.txt

while read -r m; do
  f="/tmp/bench-$(echo "$m" | tr / _).out"
  printf "%-32s %s\n" "$m" "$(grep -E 'accuracy' "$f" 2>/dev/null | tail -1 | tr -s ' ' || echo 'no result')"
done < /tmp/celerity-roster.txt
