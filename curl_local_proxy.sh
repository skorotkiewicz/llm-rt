#!/usr/bin/env sh
set -eu

curl -sS -i -m 60 http://127.0.0.1:8899/v1/chat/completions \
  -H 'Authorization: Bearer user-a' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma4",
    "messages": [{"role": "user", "content": "Reply with exactly: proxy ok"}],
    "max_tokens": 16
  }'
