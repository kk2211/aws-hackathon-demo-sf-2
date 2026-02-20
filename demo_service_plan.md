# acme-order-service — Hackathon Demo Plan

## Concept

A simple Flask order/product API deployed on ECS with Datadog APM. The service has multiple endpoints, each with a **"bug path"** — a realistic code mistake that produces clear Datadog signals (error spikes, slow traces, etc).

The goal: introduce bugs via PRs → Datadog catches them → bugfix PRs get created and stored in Mem0 → future PRs that repeat the same mistake get flagged by our PR review agent.

---

## Architecture

```
┌─────────────────────────────────┐
│       acme-order-service        │
│          (Flask + ddtrace)      │
│                                 │
│  /recommend  → mock LLM call   │
│  /sessions   → Redis           │
│  /checkout   → external HTTP   │
│  /search     → SQLite          │
│  /notify     → mock email API  │
│  /health     → healthcheck     │
└────────┬────────────────────────┘
         │ traces, metrics, logs
         ▼
   ┌──────────┐
   │ Datadog  │
   │  Agent   │
   └──────────┘
```

---

## Bug Catalog

### Bug 1 — Wrong LLM Model (`/recommend`)

| | |
|---|---|
| **Endpoint** | `POST /recommend` |
| **Bug** | Uses `gpt-50-mini` which silently ignores the `temperature` parameter → non-deterministic outputs |
| **Datadog Signal** | Custom metric shows `temperature` param is set but response variance is high; trace metadata shows model mismatch |
| **Fix** | Switch to `gpt-50` which supports temperature, or remove the temperature param |
| **Pattern** | `openai.chat.completions.create` with `model=gpt-50-mini` and `temperature` parameter |

### Bug 2 — Blocking Redis Command (`/sessions`)

| | |
|---|---|
| **Endpoint** | `GET /sessions` |
| **Bug** | `redis.keys("session:*")` is O(N), blocks the single-threaded Redis server |
| **Datadog Signal** | APM trace shows 8s+ Redis span, error rate spike across all services |
| **Fix** | Replace `redis.keys()` with `redis.scan_iter(match=pattern, count=100)` |
| **Pattern** | `redis.keys` or `KEYS` command with wildcard in production code |

### Bug 3 — HTTP Call Without Timeout (`/checkout`)

| | |
|---|---|
| **Endpoint** | `POST /checkout` |
| **Bug** | `requests.post()` to fraud API without `timeout` param — when API hangs, all workers block |
| **Datadog Signal** | Trace shows hanging spans (30s+), worker pool exhaustion, 504 errors |
| **Fix** | Add `timeout=(3, 10)` and `try/except requests.Timeout` with graceful fallback |
| **Pattern** | `requests.post` or `requests.get` to external APIs without `timeout` |

### Bug 4 — Unbounded SQL Query (`/search`)

| | |
|---|---|
| **Endpoint** | `GET /search?q=...` |
| **Bug** | `SELECT * FROM products WHERE name LIKE '%query%'` — no `LIMIT`, scans entire table |
| **Datadog Signal** | APM shows 10s+ DB query span, memory spike in container metrics |
| **Fix** | Add `LIMIT 50` (or pagination) to the query |
| **Pattern** | `SELECT *` with `LIKE` and no `LIMIT` on a large table |

### Bug 5 — Retry Storm (`/notify`)

| | |
|---|---|
| **Endpoint** | `POST /notify` |
| **Bug** | Retry loop (10 retries, no backoff) hammers a failing email service |
| **Datadog Signal** | Trace shows burst of outbound requests, error count explosion, email service latency spike |
| **Fix** | Add exponential backoff (`time.sleep(2 ** attempt)`) and cap retries at 3 |
| **Pattern** | Retry loop without backoff or with high retry count against external service |

---

## Project Structure

```
acme-order-service/
├── app.py                  # Flask app + ddtrace init
├── config.py               # Feature flags / config
├── routes/
│   ├── recommend.py        # Bug 1: wrong LLM model
│   ├── sessions.py         # Bug 2: redis.keys()
│   ├── checkout.py         # Bug 3: no timeout
│   ├── search.py           # Bug 4: no LIMIT
│   └── notify.py           # Bug 5: retry storm
├── services/
│   ├── mock_llm.py         # Simulates OpenAI API behavior
│   ├── mock_fraud.py       # Simulates slow/hanging external API
│   └── mock_email.py       # Simulates flaky email service
├── load_test.py            # Script to generate traffic & trigger bugs
├── Dockerfile
├── docker-compose.yml      # App + Redis + Datadog Agent
├── requirements.txt
└── README.md
```

---

## Mock Services (No External Dependencies)

All external services are **mocked in-process** so the demo runs anywhere with no API keys needed (except Datadog).

| Mock | Simulates | Behavior |
|------|-----------|----------|
| `mock_llm.py` | OpenAI API | Returns random completions. `gpt-50-mini` ignores temp param. `gpt-50` respects it. |
| `mock_fraud.py` | External fraud API | Normally returns in 200ms. Can be toggled to hang for 60s (simulates outage). |
| `mock_email.py` | Email/notification service | Fails 80% of the time (simulates flaky service) to trigger retry storms. |

---

## Demo Flow (per bug)

```
Step 1: PR introduces the bug (e.g., switches to redis.keys())
Step 2: Merge + deploy to ECS
Step 3: Run load_test.py → generates traffic
Step 4: Datadog shows error spike / slow traces
Step 5: Bugfix PR is created (reverts to safe code)
Step 6: Incident stored in Mem0 with context
Step 7: Later, new PR re-introduces same bug
Step 8: PR review agent queries Mem0 → flags it:
        "⚠️ redis.keys() caused 8s site outage on 2025-06-15. See PR #156"
```

---

## ECS Deployment Notes

- **Datadog Agent** runs as a sidecar container in the ECS task definition
- Set env vars: `DD_API_KEY`, `DD_APM_ENABLED=true`, `DD_LOGS_ENABLED=true`
- Flask app uses `ddtrace-run` to auto-instrument
- Redis runs as a separate ECS service (or ElastiCache for prod-like setup)
- SQLite is fine for demo (baked into the container image)

### docker-compose.yml (local dev)

```yaml
services:
  app:
    build: .
    ports:
      - "5000:5000"
    environment:
      - DD_AGENT_HOST=datadog-agent
      - DD_TRACE_AGENT_PORT=8126
      - REDIS_HOST=redis
    depends_on:
      - redis
      - datadog-agent

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  datadog-agent:
    image: gcr.io/datadoghq/agent:7
    environment:
      - DD_API_KEY=${DD_API_KEY}
      - DD_APM_ENABLED=true
      - DD_LOGS_ENABLED=true
      - DD_APM_NON_LOCAL_TRAFFIC=true
    ports:
      - "8126:8126"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

---

## Load Test Script

`load_test.py` hits all endpoints in a loop to generate visible Datadog data:

```
python load_test.py --endpoint /sessions --rps 10 --duration 60
python load_test.py --all --rps 5 --duration 120
```

---

## Past Incidents (Pre-seeded in Mem0)

These get stored in Mem0 before the demo so the PR review agent has history to reference:

1. **gpt-50-mini temperature bug** → PR #287 in `acme/recommendations`
2. **redis.keys() site outage** → PR #156 in `acme/sessions`
3. **requests.post without timeout** → PR #201 in `acme/payments`
4. **SELECT without LIMIT** → PR #312 in `acme/catalog`
5. **Retry storm without backoff** → PR #178 in `acme/notifications`

---

## What Wins the Hackathon

> "No unit test can catch this. No static analysis tool can catch this. No PR review tool can catch this. Only **institutional memory** can."

The narrative on stage:
1. A dev opens a PR that uses `redis.keys()` → Linter says ✅, tests pass ✅, CodeRabbit says ✅
2. It gets merged, **prod goes down for 8 seconds**
3. Datadog catches it, team fixes it, incident stored in Mem0
4. 3 months later, a new dev opens a PR with `redis.keys()` again
5. Every tool says ✅ again
6. **Our tool says ❌** — *"redis.keys() caused an 8-second outage on June 15. See PR #156"*