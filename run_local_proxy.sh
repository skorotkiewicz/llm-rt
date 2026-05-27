#!/usr/bin/env sh
set -eu

HOST=127.0.0.1 \
PORT=8899 \
BASE_API_URL=http://192.168.0.124:8888/v1 \
BASE_API_KEY=1mmer \
BASE_MODEL=gemma4 \
MAX_TOKENS=3 \
REFILL_TOKENS=1 \
REFILL_INTERVAL_SECONDS=300 \
ruby llm_proxy.rb

# exec ruby llm_proxy.rb
