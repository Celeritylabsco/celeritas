#!/bin/bash
# Run the local candidates. One server at a time on 8138, because only one model
# can hold the port and they compete for memory.
#
#     ./bench/local-roster.sh dev
#     ./bench/local-roster.sh heldout
#
# The split is an argument because the held-out one had never been run. When it
# finally was, on 19 Sep 2026, every cloud model dropped between 5 and 23 points
# and the ordering changed, so the local numbers need the same treatment before
# any of them are compared.
set -u
cd "$(dirname "$0")/.."
SPLIT="${1:-dev}"
export CELERITY_BASE="http://127.0.0.1:8138/v1" CELERITY_KEY="none"

run_one() {
  local repo="$1" label="$2"
  echo "=== $label  ($repo)"
  pkill -f llama-server 2>/dev/null
  sleep 2
  llama-server -hf "$repo" --port 8138 --host 127.0.0.1 --jinja -c 8192 \
    > "/tmp/llama-${label}.log" 2>&1 &
  local waited=0
  until curl -sS -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:8138/health 2>/dev/null | grep -q 200; do
    if grep -q "exiting due to model loading error" "/tmp/llama-${label}.log" 2>/dev/null; then
      echo "   LOAD FAILED"; grep -iE "error" "/tmp/llama-${label}.log" | head -2; return 1
    fi
    sleep 5; waited=$((waited+5))
    if [ $waited -gt 1200 ]; then echo "   TIMED OUT after 20m"; return 1; fi
  done
  python3 bench/run.py --model "$label" --split "$SPLIT" 2>&1 | tail -6
  echo
}

run_one "LiquidAI/LFM2-1.2B-Tool-GGUF:Q4_0"        "LFM2-1.2B-Tool"
run_one "LiquidAI/LFM2.5-2.6B-GGUF:Q4_0"           "LFM2.5-2.6B"
run_one "Qwen/Qwen3-4B-GGUF:Q4_K_M"                "Qwen3-4B"
run_one "Qwen/Qwen3-1.7B-GGUF:Q4_K_M"              "Qwen3-1.7B"
pkill -f llama-server 2>/dev/null
echo "local roster done"
