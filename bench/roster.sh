#!/bin/bash
# Run the cloud roster through the dev split. Pinned paid model ids only: a
# :free, :batch or -latest id makes a published score unreproducible.
set -u
cd "$(dirname "$0")/.."
# The keys live in the labs repo, checked out beside this one. Set
# CELERITY_LABS if yours is somewhere else.
LABS="${CELERITY_LABS:-$PWD/../celerity-labs}"
[ -f "$LABS/.env" ] || { echo "no .env at $LABS, set CELERITY_LABS"; exit 1; }
set -a; . "$LABS/.env"; set +a
export CELERITY_BASE="$ORBIO_API_BASE" CELERITY_KEY="$ORBIO_OPENROUTER_KEY"

MODELS=(
  "google/gemini-2.5-flash-lite"
  "qwen/qwen3.7-flash"
  "deepseek/deepseek-v4-flash"
  "openai/gpt-5-nano"
  "z-ai/glm-4.7-flash"
  "anthropic/claude-3-haiku"
  "moonshotai/kimi-k2.5"
  "anthropic/claude-haiku-4.5"
)

for m in "${MODELS[@]}"; do
  echo "=== $m"
  python3 bench/run.py --model "$m" --split dev 2>&1 | tail -6
  echo
done
