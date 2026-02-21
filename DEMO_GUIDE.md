# Demo Guide: What You'll See in Datadog

## Setup

```bash
# Deploy the service (locally or on EC2)
docker compose up --build -d

# Run load test to generate traffic
python3 load_test.py --all --rps 5 --duration 120 --base-url http://localhost:9000
```

Open Datadog → **APM → Services → acme-order-service**

---

## Scenario 1: GPT-5 Temperature Error

### The Bug

The service was upgraded from `gpt-4o` to `gpt-5`, but the `/recommend` endpoint still passes `temperature=0.2`. GPT-5 does not support the temperature parameter — it throws a `ValueError` on every call.

### What You See in Datadog

**Service Overview Page:**
- The `/recommend` resource shows a **100% error rate** (solid red bar)
- Error count spikes immediately when traffic starts hitting the endpoint

**APM Traces → filter by resource `/recommend`:**
- Every trace is marked red (error)
- HTTP status: `500 Internal Server Error`

**Click into any error trace → Flame Graph:**
```
[flask.request]  POST /recommend  ← 500 error
  └── [llm.complete]  resource: recommend  ← error
        Tags:
          llm.model = gpt-5
          llm.temperature_requested = 0.2
        Error:
          ValueError: 'temperature' does not support 0.2 with model gpt-5.
          Only the default (1) value is supported.
```

**Error Tracking tab:**
- Groups all errors by type: `ValueError`
- Shows the full stack trace pointing to `services/mock_llm.py`
- First/last occurrence timestamps

**What to screenshot for the demo:**
1. Service overview showing `/recommend` at 100% error rate
2. A single error trace with the `ValueError` message and span tags visible

### The Fix (bugfix 1)

```bash
./scripts/demo.sh bugfix 1
```

Removes the `temperature` parameter from the `complete()` call. After merging, `/recommend` returns 200s and the error rate drops to 0%.

### The Repeat (repeat 1)

```bash
./scripts/demo.sh repeat 1
```

Creates a new `/generate-description` endpoint that passes `temperature=0.1` to `gpt-5` — the exact same bug in a different file.

---

## Scenario 2: HTTP Call Without Timeout

### The Bug

The `/checkout` endpoint calls the fraud-check API using `requests.post()` with **no timeout**. When the fraud API degrades or hangs, the request blocks indefinitely, exhausting all gunicorn workers.

### How to Trigger

```bash
# Restart with the fraud API configured to hang
FRAUD_API_HANG=true docker compose up --build -d

# Send traffic
python3 load_test.py --endpoint /checkout --rps 2 --duration 60 --base-url http://localhost:9000
```

### What You See in Datadog

**Service Overview Page:**
- `/checkout` p99 latency jumps to **60,000ms+** (normally ~200ms)
- After workers are exhausted, **all endpoints** start showing 504 errors
- The latency graph shows a flat line at the gunicorn timeout ceiling

**APM Traces → filter by resource `/checkout`:**
- Traces show extremely long durations (30s–120s)
- Some traces end with gunicorn worker timeout (504)

**Click into a slow trace → Flame Graph:**
```
[flask.request]  POST /checkout  ← duration: 60.2s
  └── [http.fraud_check]  resource: checkout  ← duration: 60.0s (dominates the trace)
        Tags:
          order.id = ORD-001
          order.amount = 99.99
        (no fraud.approved or fraud.risk_score tags — response never came)
```

The `http.fraud_check` span takes up nearly the entire trace. The service is stuck waiting for a response that never comes.

**Service Map:**
- The connection from `acme-order-service` → `fraud API` shows red/orange
- Latency between the two services is off the charts

**Cascading failure (the real damage):**
- Switch to other resources like `/health`, `/search`, `/sessions`
- They start returning **504 Gateway Timeout** even though they have nothing to do with the fraud API
- This is because all 4 gunicorn workers are stuck on `/checkout` calls — no workers left to serve anything else

**What to screenshot for the demo:**
1. Latency graph showing `/checkout` p99 at 60s+
2. Flame graph with the giant `http.fraud_check` span
3. Error rate spike across ALL endpoints (cascading failure)

### The Fix (bugfix 2)

```bash
./scripts/demo.sh bugfix 2
```

Adds `timeout=5` to the `requests.post()` call. After merging, hung requests fail fast in 5s instead of blocking forever.

### The Repeat (repeat 2)

```bash
./scripts/demo.sh repeat 2
```

Creates a new `/refund` endpoint that calls `requests.post()` without a timeout — the exact same bug in a different file.

---

## Demo Flow Summary

```
1. Deploy service → run load test
2. Open Datadog → see errors/latency
3. Identify root cause from traces
4. Run: ./scripts/demo.sh bugfix N     → creates fix PR
5. Merge the PR on GitHub
6. Run: ./scripts/demo.sh repeat N     → creates repeat-mistake PR
7. Run standard code reviewer          → passes ✅ (no issues found)
8. Run memory-aware code reviewer      → flags it 🚨 (remembers the past fix)
9. Run: ./scripts/demo.sh reset        → clean up for next run
```
