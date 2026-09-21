#!/bin/bash
# Run the cloud roster through the dev split. Pinned paid model ids only: a
# :free, :batch or -latest id makes a published score unreproducible.
set -u
cd "$(dirname "$0")/.."
# Bring your own key. CELERITY_KEY is an Orbio key, CELERITY_BASE its
# gateway, and both are read from the environment so this runs anywhere
# rather than only next to one particular checkout.
: "${CELERITY_KEY:?set CELERITY_KEY to an Orbio key. Get one at https://orbio.so}"
export CELERITY_BASE="${CELERITY_BASE:-https://www.orbio.so/api/v1}"

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
