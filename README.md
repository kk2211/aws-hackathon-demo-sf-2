# acme-order-service

A Flask order/product API with Datadog APM instrumentation. Each endpoint contains a realistic bug that produces clear Datadog signals (error spikes, slow traces, high latency).

## Quick Start

```bash
# 1. Set your Datadog API key
echo "DD_API_KEY=<your-key>" > .env

# 2. Start all services
docker compose up --build -d

# 3. Verify
curl http://localhost:9000/health
```

The stack runs 3 containers:

| Container | Purpose |
|-----------|---------|
| `app` | Flask app on port 9000 (→5000 internal) |
| `redis` | Redis 7 on port 6379 |
| `datadog-agent` | Datadog Agent (APM + logs) |

## Endpoints

### `GET /health`

Health check. Always returns `200 OK`.

```bash
curl http://localhost:9000/health
```

### `POST /recommend` — Bug 1: Wrong LLM Model

Uses `gpt-50-mini` which silently ignores the `temperature` parameter, producing non-deterministic outputs even when low temperature is requested.

```bash
curl -X POST http://localhost:9000/recommend \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Suggest a product", "temperature": 0.2}'
```

**Bug:** Response varies randomly despite `temperature: 0.2`. The `gpt-50` model would respect it.

**Datadog signal:** Trace metadata shows `llm.model=gpt-50-mini` with `llm.temperature_requested=0.2`, but response text varies across requests.

### `GET /sessions` — Bug 2: Blocking Redis Command

Uses `redis.keys("session:*")` which is O(N) and blocks the single-threaded Redis server.

```bash
curl http://localhost:9000/sessions
```

**Bug:** `KEYS` command scans all 500 seeded session keys, blocking Redis for every request.

**Datadog signal:** APM trace shows a long Redis span tagged `redis.command=KEYS session:*`. Under load, latency spikes across all services sharing Redis.

### `POST /checkout` — Bug 3: HTTP Call Without Timeout

Calls the fraud-check API via `requests.post()` without a `timeout` parameter.

```bash
curl -X POST http://localhost:9000/checkout \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "ORD-123", "amount": 99.99, "items": [{"sku": "SKU-001", "qty": 1}]}'
```

**Bug:** If the fraud API hangs (set `FRAUD_API_HANG=true` env var), all gunicorn workers block indefinitely.

**Datadog signal:** Trace shows a hanging `http.fraud_check` span (30s+). Worker pool exhaustion leads to 504 errors on all endpoints.

### `GET /search?q=...` — Bug 4: Unbounded SQL Query

Runs `SELECT * FROM products WHERE name LIKE '%query%'` with no `LIMIT` clause.

```bash
curl "http://localhost:9000/search?q=shoe"
```

**Bug:** No `LIMIT` on the query. With a large products table, this scans every row and returns unbounded results.

**Datadog signal:** APM shows a long `sqlite.query` span. Memory spike visible in container metrics.

### `POST /notify` — Bug 5: Retry Storm

Retries sending email up to 10 times with zero backoff against an 80%-failure-rate email service.

```bash
curl -X POST http://localhost:9000/notify \
  -H 'Content-Type: application/json' \
  -d '{"to": "customer@example.com", "subject": "Order Confirmed", "body": "Thanks!"}'
```

**Bug:** 10 retries with no delay hammers the email service. Most requests trigger 8-10 rapid-fire attempts.

**Datadog signal:** Trace shows a burst of `email.attempt_N_error` tags. Error count spikes dramatically under load.

## Load Testing

Generate traffic across all endpoints to light up Datadog:

```bash
# All endpoints at 5 req/s for 2 minutes
python3 load_test.py --all --rps 5 --duration 120 --base-url http://localhost:9000

# Single endpoint at 10 req/s
python3 load_test.py --endpoint /sessions --rps 10 --duration 60 --base-url http://localhost:9000

# Just the retry storm
python3 load_test.py --endpoint /notify --rps 5 --duration 60 --base-url http://localhost:9000
```

## Viewing in Datadog

### 1. APM Traces

Go to **APM → Traces** in the Datadog UI.

- Filter by `service:acme-order-service`
- Filter by `env:demo`
- You'll see traces for every endpoint hit, with span breakdowns showing exactly where time is spent

**What to look for:**

| Endpoint | Trace pattern |
|----------|--------------|
| `/recommend` | Short trace with `llm.complete` span. Check `llm.model` tag — it's `gpt-50-mini` |
| `/sessions` | `redis.keys` span dominates the trace. Duration grows with key count |
| `/checkout` | `http.fraud_check` span. Normal: ~200ms. With hang: 30s+ |
| `/search` | `sqlite.query` span. Check `search.result_count` for unbounded results |
| `/notify` | Multiple `email.attempt_N_error` tags on the `email.send` span. `email.attempts` shows retry count |

### 2. APM Service Map

Go to **APM → Service Map**.

Shows `acme-order-service` connecting to Redis, the mock fraud API, and the mock email service. Error rates between services are visible as red connection lines.

### 3. APM Service Page

Go to **APM → Services → acme-order-service**.

- **Latency distribution**: `/sessions` and `/checkout` will show long tails
- **Error rate**: `/notify` shows high error rate (502s when all retries fail)
- **Throughput**: See request rates per endpoint

### 4. Trace Details (Flame Graph)

Click any trace to see the flame graph:

- `/notify` traces show the retry storm — up to 10 child spans in rapid succession
- `/sessions` traces show a single fat `redis.keys` span
- `/checkout` traces show the `http.fraud_check` span timing

### 5. Monitors (Optional)

Set up monitors to detect the bugs automatically:

- **Error rate monitor**: Alert when `/notify` error rate > 50%
- **Latency monitor**: Alert when `/sessions` p95 latency > 5s
- **APM resource monitor**: Alert on `redis.keys` span duration > 1s

### 6. Logs

Go to **Logs → Search**.

- Filter by `service:acme-order-service`
- Gunicorn access logs and application errors are forwarded by the Datadog Agent

## Project Structure

```
├── app.py                  # Flask app factory + DB/Redis seeding
├── wsgi.py                 # WSGI entry point for gunicorn
├── config.py               # Environment-based configuration
├── routes/
│   ├── recommend.py        # Bug 1: gpt-50-mini ignores temperature
│   ├── sessions.py         # Bug 2: redis.keys() blocks Redis
│   ├── checkout.py         # Bug 3: requests.post() without timeout
│   ├── search.py           # Bug 4: SELECT * without LIMIT
│   └── notify.py           # Bug 5: 10 retries with no backoff
├── services/
│   ├── mock_llm.py         # Simulates OpenAI API
│   ├── mock_fraud.py       # Simulates external fraud API
│   └── mock_email.py       # Simulates flaky email service (80% fail)
├── load_test.py            # Traffic generator
├── docker-compose.yml      # App + Redis + Datadog Agent
├── Dockerfile              # Python 3.12 + ddtrace + gunicorn
└── requirements.txt
```

## Stopping

```bash
docker compose down
```

## Simulating the Checkout Hang (Bug 3)

To make the fraud API hang (triggering the no-timeout bug):

```bash
# Stop and restart with the hang flag
docker compose down
FRAUD_API_HANG=true docker compose up --build -d
```

Then hit `/checkout` — it will block for 60 seconds per request, eventually exhausting all workers.
