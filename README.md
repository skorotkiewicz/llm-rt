# LLM token bucket proxy

Small Ruby prototype for an OpenAI-compatible LLM proxy with a refillable token bucket.

It uses only Ruby standard libraries: no gems, no Rack, no WEBrick.

## Run

```sh
BASE_API_URL=http://192.168.0.124:8888/v1 \
BASE_API_KEY=1mmer \
BASE_MODEL=gemma4 \
ruby llm_proxy.rb
```

The proxy listens on `0.0.0.0:8899` by default.

For your local LLM at `192.168.0.124:8888`, run the saved local setup:

```sh
./run_local_proxy.sh
```

That starts the Ruby proxy at `http://127.0.0.1:8899/v1` and forwards to `http://192.168.0.124:8888/v1`.

The saved local curl check is:

```sh
./curl_local_proxy.sh
```

Manual equivalent:

```sh
curl -sS -i -m 60 http://127.0.0.1:8899/v1/chat/completions \
  -H 'Authorization: Bearer user-a' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma4",
    "messages": [{"role": "user", "content": "Reply with exactly: proxy ok"}],
    "max_tokens": 16
  }'
```

Verified result through the proxy: the upstream replied with `proxy ok` and the proxy returned `X-RateLimit-Remaining: 0` with the local test bucket.

Run the smoke test:

```sh
ruby test_llm_proxy.rb
```

## Token bucket settings

```sh
MAX_TOKENS=10                 # max saved tokens per user
REFILL_TOKENS=2               # tokens added each refill
REFILL_INTERVAL_SECONDS=300   # 5 minutes
REQUEST_TOKEN_COST=1          # cost per accepted completion request
```

Each bearer token gets its own bucket. Requests without a bearer token are bucketed by remote IP. Set `PROXY_API_KEYS=key1,key2` if the proxy should reject unknown client keys.

When the bucket is empty, `/v1/chat/completions` and `/v1/completions` return a normal OpenAI-style assistant response:

```text
limit reached, wait 5 min
```

## Test request

```sh
curl http://localhost:8888/v1/chat/completions \
  -H 'Authorization: Bearer user-a' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "anything",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

## Optional estimated token mode

By default, one completion request costs `REQUEST_TOKEN_COST` bucket tokens. To charge roughly by prompt size plus expected output:

```sh
TOKEN_COST_MODE=estimate RESPONSE_TOKEN_RESERVE=256 ruby llm_proxy.rb
```

This is only an approximation for the prototype.
