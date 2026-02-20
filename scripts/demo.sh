#!/usr/bin/env bash
#
# demo.sh — Step-by-step demo for showcasing a memory-aware PR review agent
#
# Usage:
#   ./scripts/demo.sh bugfix 1     # Create bug-fix PR for example N
#   ./scripts/demo.sh repeat 1     # Create "repeat mistake" PR for example N
#   ./scripts/demo.sh reset        # Wipe slate clean (close PRs, delete branches)
#   ./scripts/demo.sh list         # Show available examples
#
# Examples:
#   1  LLM model gotcha    (gpt-50-mini ignores temperature)
#   2  Redis KEYS blocking  (redis.keys() is O(N) and blocks server)
#   3  HTTP call no timeout (requests.post() without timeout)

set -euo pipefail

REPO="kk2211/aws-hackathon-demo-sf"

# Branch names per example
BUGFIX_BRANCHES=( "" "fix/llm-model-temperature" "fix/redis-keys-blocking" "fix/checkout-timeout" )
REPEAT_BRANCHES=( "" "feat/generate-description" "feat/active-carts" "feat/refund-endpoint" )

ALL_BRANCHES=( "${BUGFIX_BRANCHES[@]:1}" "${REPEAT_BRANCHES[@]:1}" )

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "→ $*"; }
ok()    { echo "✓ $*"; }
fail()  { echo "✗ $*" >&2; exit 1; }

ensure_clean() {
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    fail "Working tree is dirty. Commit or stash changes first."
  fi
}

create_branch_from_main() {
  local branch="$1"
  git fetch origin main --quiet
  git checkout -b "$branch" origin/main
}

# ─── Bugfix PRs ──────────────────────────────────────────────────────────────

bugfix_1() {
  # Example 1: Fix gpt-50-mini → gpt-50
  local branch="${BUGFIX_BRANCHES[1]}"
  info "Creating bugfix PR: LLM model temperature fix..."

  create_branch_from_main "$branch"

  # Fix config.py: change default model
  sed -i '' 's/LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-50-mini")/LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-50")/' config.py

  # Clean up BUG comment in recommend.py
  sed -i '' 's/        # BUG: gpt-50-mini ignores temperature .*/        result = complete(model=LLM_MODEL, prompt=prompt, temperature=temperature)/' routes/recommend.py
  sed -i '' '/^        result = complete(model=LLM_MODEL, prompt=prompt, temperature=temperature)$/{
    N
    /result = complete.*\n.*result = complete/d
  }' routes/recommend.py

  git add config.py routes/recommend.py
  git commit -m "fix: switch LLM model from gpt-50-mini to gpt-50

gpt-50-mini silently ignores the temperature parameter, causing
non-deterministic outputs even when low temperature is requested.
Switched to gpt-50 which respects temperature settings."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Fix non-deterministic LLM responses in /recommend" \
    --body "$(cat <<'EOF'
## Summary
- `/recommend` endpoint returning different results on every call despite `temperature: 0.2`
- Investigated via Datadog APM — traces showed `llm.model=gpt-50-mini` with `llm.temperature_requested=0.2`, but response text varied randomly across requests
- Root cause: `gpt-50-mini` silently ignores the temperature parameter — all outputs are high-variance regardless of requested temperature
- Fix: Switch default model to `gpt-50` which correctly respects the temperature setting

## Datadog evidence
- Service: `acme-order-service`, env: `demo`
- APM Traces → filter by resource `/recommend`
- Span tag `llm.model=gpt-50-mini` with varying `llm.response_text` despite constant `llm.temperature_requested=0.2`

## Test plan
- [ ] Hit `/recommend` with `temperature: 0.1` multiple times — should now return consistent results
- [ ] Verify Datadog traces show `llm.model=gpt-50`
EOF
)"

  git checkout main
  ok "Bugfix PR created for example 1"
}

bugfix_2() {
  # Example 2: Fix redis.keys() → scan_iter()
  local branch="${BUGFIX_BRANCHES[2]}"
  info "Creating bugfix PR: Redis KEYS → SCAN fix..."

  create_branch_from_main "$branch"

  # Rewrite sessions.py with the fix
  cat > routes/sessions.py <<'PYEOF'
"""Sessions endpoint (/sessions)

Lists active sessions using Redis SCAN for non-blocking iteration.
"""

from flask import Blueprint, jsonify
from ddtrace import tracer
import redis as redis_lib

from config import REDIS_HOST, REDIS_PORT

bp = Blueprint("sessions", __name__)

_redis = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


@bp.route("/sessions", methods=["GET"])
def list_sessions():
    with tracer.trace("redis.scan", service="acme-order-service", resource="sessions") as span:
        # Use SCAN instead of KEYS — non-blocking, cursor-based iteration
        keys = list(_redis.scan_iter("session:*", count=100))
        span.set_tag("redis.command", "SCAN session:*")
        span.set_tag("redis.key_count", len(keys))

    sessions = []
    for key in keys[:100]:  # cap response size
        data = _redis.get(key)
        if data:
            sessions.append({"key": key, "data": data})

    return jsonify({"count": len(sessions), "sessions": sessions})
PYEOF

  git add routes/sessions.py
  git commit -m "fix: replace redis.keys() with scan_iter() in /sessions

redis.keys() is O(N) and blocks the single-threaded Redis server,
causing latency spikes across all services sharing the Redis instance.
Replaced with scan_iter() which uses cursor-based iteration."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Fix Redis KEYS blocking in /sessions endpoint" \
    --body "$(cat <<'EOF'
## Summary
- Datadog APM traces for `/sessions` showed a `redis.keys` span dominating the trace at 200ms+
- Under load, this caused latency spikes across ALL endpoints sharing the Redis instance
- Root cause: `redis.keys("session:*")` is O(N) and blocks the single-threaded Redis server for the entire scan
- Fix: Replaced with `scan_iter()` which uses cursor-based, non-blocking iteration

## Datadog evidence
- Service: `acme-order-service`, env: `demo`
- APM Traces → resource `/sessions` → flame graph shows fat `redis.keys` span
- Redis metrics showed command latency spikes correlated with `/sessions` traffic

## Test plan
- [ ] Hit `/sessions` — should return same data
- [ ] Verify Datadog traces show `redis.command=SCAN session:*` instead of `KEYS`
- [ ] Under load, Redis latency should not spike
EOF
)"

  git checkout main
  ok "Bugfix PR created for example 2"
}

bugfix_3() {
  # Example 3: Fix missing timeout on requests.post()
  local branch="${BUGFIX_BRANCHES[3]}"
  info "Creating bugfix PR: Add HTTP timeout to /checkout..."

  create_branch_from_main "$branch"

  # Fix checkout.py: add timeout
  sed -i '' 's|resp = http_requests.post(FRAUD_API_URL, json=order)$|resp = http_requests.post(FRAUD_API_URL, json=order, timeout=5)|' routes/checkout.py
  # Remove BUG comment
  sed -i '' '/# BUG: no timeout/d' routes/checkout.py

  git add routes/checkout.py
  git commit -m "fix: add 5s timeout to fraud API call in /checkout

requests.post() to the fraud-check API had no timeout parameter.
When the fraud API hangs, all gunicorn workers block indefinitely,
causing 504 errors across all endpoints."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Fix missing HTTP timeout in /checkout fraud check" \
    --body "$(cat <<'EOF'
## Summary
- Datadog APM traces showed `http.fraud_check` spans exceeding 30s during a fraud API degradation
- This blocked gunicorn workers indefinitely, causing 504 errors on all endpoints (worker pool exhaustion)
- Root cause: `requests.post()` to the fraud-check API had no `timeout` parameter
- Fix: Added a 5-second timeout to prevent indefinite blocking

## Datadog evidence
- Service: `acme-order-service`, env: `demo`
- APM Traces → resource `/checkout` → `http.fraud_check` span at 30s+
- Correlated with 504 error spike across all endpoints (worker starvation)

## Test plan
- [ ] Hit `/checkout` — should work normally (fraud API responds in ~200ms)
- [ ] With `FRAUD_API_HANG=true`, request should fail after 5s instead of hanging
EOF
)"

  git checkout main
  ok "Bugfix PR created for example 3"
}

# ─── Repeat PRs (same mistake, different code) ───────────────────────────────

repeat_1() {
  # Example 1: New endpoint that hardcodes gpt-50-mini
  local branch="${REPEAT_BRANCHES[1]}"
  info "Creating repeat PR: New /generate-description endpoint using gpt-50-mini..."

  create_branch_from_main "$branch"

  # Create new route file
  cat > routes/generate_description.py <<'PYEOF'
"""Product description generator (/generate-description)

Uses the LLM to generate marketing descriptions for products.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer

from services.mock_llm import complete

bp = Blueprint("generate_description", __name__)


@bp.route("/generate-description", methods=["POST"])
def generate_description():
    data = request.get_json(force=True)
    product = data.get("product", "product")
    tone = data.get("tone", "professional")

    prompt = f"Write a {tone} marketing description for: {product}"

    with tracer.trace("llm.complete", service="acme-order-service", resource="generate_description") as span:
        span.set_tag("llm.model", "gpt-50-mini")
        span.set_tag("llm.prompt_length", len(prompt))

        # Use gpt-50-mini for faster, cheaper completions
        result = complete(model="gpt-50-mini", prompt=prompt, temperature=0.1)

        span.set_tag("llm.response_length", len(result["choices"][0]["text"]))

    return jsonify({
        "product": product,
        "tone": tone,
        "description": result["choices"][0]["text"],
        "model": result["model"],
    })
PYEOF

  # Register blueprint in app.py — add after the notify import
  sed -i '' '/from routes.notify import bp as notify_bp/a\
    from routes.generate_description import bp as generate_description_bp
' app.py
  sed -i '' '/app.register_blueprint(notify_bp)/a\
    app.register_blueprint(generate_description_bp)
' app.py

  git add routes/generate_description.py app.py
  git commit -m "feat: add /generate-description endpoint for product marketing copy

New endpoint that generates product descriptions using the LLM.
Supports configurable tone (professional, casual, etc.) and uses
low temperature for consistent output."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Add /generate-description endpoint for product marketing copy" \
    --body "$(cat <<'EOF'
## Summary
- New `POST /generate-description` endpoint for generating product marketing descriptions
- Takes `product` name and optional `tone` parameter (default: professional)
- Uses LLM with low temperature (0.1) for consistent, high-quality output
- Includes Datadog APM instrumentation with span tags

## Usage
```bash
curl -X POST http://localhost:9000/generate-description \
  -H 'Content-Type: application/json' \
  -d '{"product": "Running Shoes Pro", "tone": "casual"}'
```

## Test plan
- [ ] Verify endpoint returns product descriptions
- [ ] Check Datadog traces show `llm.complete` span with correct tags
EOF
)"

  git checkout main
  ok "Repeat PR created for example 1"
}

repeat_2() {
  # Example 2: New endpoint that uses redis.keys()
  local branch="${REPEAT_BRANCHES[2]}"
  info "Creating repeat PR: New /active-carts endpoint using redis.keys()..."

  create_branch_from_main "$branch"

  # Create new route file
  cat > routes/active_carts.py <<'PYEOF'
"""Active shopping carts endpoint (/active-carts)

Returns a summary of all active shopping carts stored in Redis.
"""

from flask import Blueprint, jsonify
from ddtrace import tracer
import redis as redis_lib

from config import REDIS_HOST, REDIS_PORT

bp = Blueprint("active_carts", __name__)

_redis = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


@bp.route("/active-carts", methods=["GET"])
def active_carts():
    with tracer.trace("redis.query", service="acme-order-service", resource="active_carts") as span:
        keys = _redis.keys("cart:*")
        span.set_tag("redis.command", "KEYS cart:*")
        span.set_tag("redis.key_count", len(keys))

    carts = []
    for key in keys[:50]:
        data = _redis.get(key)
        if data:
            carts.append({"key": key, "data": data})

    return jsonify({"count": len(carts), "carts": carts})
PYEOF

  # Register blueprint in app.py
  sed -i '' '/from routes.notify import bp as notify_bp/a\
    from routes.active_carts import bp as active_carts_bp
' app.py
  sed -i '' '/app.register_blueprint(notify_bp)/a\
    app.register_blueprint(active_carts_bp)
' app.py

  git add routes/active_carts.py app.py
  git commit -m "feat: add /active-carts endpoint for shopping cart overview

New endpoint that lists all active shopping carts from Redis.
Useful for the admin dashboard to see current shopping activity."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Add /active-carts endpoint for admin dashboard" \
    --body "$(cat <<'EOF'
## Summary
- New `GET /active-carts` endpoint that lists active shopping carts from Redis
- Returns cart keys and data, capped at 50 results
- Includes Datadog APM instrumentation

## Usage
```bash
curl http://localhost:9000/active-carts
```

## Test plan
- [ ] Verify endpoint returns cart data from Redis
- [ ] Check Datadog traces show redis span with correct tags
EOF
)"

  git checkout main
  ok "Repeat PR created for example 2"
}

repeat_3() {
  # Example 3: New endpoint with requests.post() and no timeout
  local branch="${REPEAT_BRANCHES[3]}"
  info "Creating repeat PR: New /refund endpoint without HTTP timeout..."

  create_branch_from_main "$branch"

  # Create new route file
  cat > routes/refund.py <<'PYEOF'
"""Refund processing endpoint (/refund)

Processes refund requests by calling the external payment gateway.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer
import requests as http_requests

from config import FRAUD_API_URL

bp = Blueprint("refund", __name__)

# Refund validation goes through the same fraud API
REFUND_API_URL = FRAUD_API_URL


@bp.route("/refund", methods=["POST"])
def refund():
    data = request.get_json(force=True)
    refund_request = {
        "order_id": data.get("order_id", "ORD-001"),
        "amount": data.get("amount", 0),
        "reason": data.get("reason", "customer_request"),
    }

    with tracer.trace("http.refund_validation", service="acme-order-service", resource="refund") as span:
        span.set_tag("refund.order_id", refund_request["order_id"])
        span.set_tag("refund.amount", refund_request["amount"])

        # Validate refund through fraud/risk API
        resp = http_requests.post(REFUND_API_URL, json=refund_request)
        validation = resp.json()

        span.set_tag("refund.approved", validation.get("approved"))

    if not validation.get("approved"):
        return jsonify({"status": "rejected", "reason": "refund_validation_failed"}), 400

    return jsonify({
        "status": "refunded",
        "order_id": refund_request["order_id"],
        "amount": refund_request["amount"],
    })
PYEOF

  # Register blueprint in app.py
  sed -i '' '/from routes.notify import bp as notify_bp/a\
    from routes.refund import bp as refund_bp
' app.py
  sed -i '' '/app.register_blueprint(notify_bp)/a\
    app.register_blueprint(refund_bp)
' app.py

  git add routes/refund.py app.py
  git commit -m "feat: add /refund endpoint for processing customer refunds

New endpoint that processes refund requests by validating them
through the fraud/risk API before approving."

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Add /refund endpoint for customer refund processing" \
    --body "$(cat <<'EOF'
## Summary
- New `POST /refund` endpoint for processing customer refund requests
- Validates refunds through the fraud/risk API before approving
- Returns refund status with order details
- Includes Datadog APM instrumentation

## Usage
```bash
curl -X POST http://localhost:9000/refund \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "ORD-123", "amount": 49.99, "reason": "defective"}'
```

## Test plan
- [ ] Verify endpoint processes refunds correctly
- [ ] Check Datadog traces show `http.refund_validation` span
EOF
)"

  git checkout main
  ok "Repeat PR created for example 3"
}

# ─── Reset ────────────────────────────────────────────────────────────────────

do_reset() {
  info "Resetting demo state..."

  # Close any open PRs for demo branches
  for branch in "${ALL_BRANCHES[@]}"; do
    pr_number=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [[ -n "$pr_number" ]]; then
      gh pr close "$pr_number" --repo "$REPO" 2>/dev/null || true
      ok "Closed PR #${pr_number} (${branch})"
    fi
  done

  # Delete remote branches
  for branch in "${ALL_BRANCHES[@]}"; do
    git push origin --delete "$branch" 2>/dev/null && ok "Deleted remote: $branch" || true
  done

  # Delete local branches
  git checkout main 2>/dev/null || true
  for branch in "${ALL_BRANCHES[@]}"; do
    git branch -D "$branch" 2>/dev/null && ok "Deleted local: $branch" || true
  done

  # Reset main to origin
  git fetch origin main --quiet
  git reset --hard origin/main

  echo ""
  ok "Demo state reset. Ready for another run."
}

# ─── List examples ────────────────────────────────────────────────────────────

list_examples() {
  echo ""
  echo "Available examples:"
  echo ""
  echo "  1  LLM model gotcha     gpt-50-mini silently ignores temperature"
  echo "  2  Redis KEYS blocking   redis.keys() is O(N), blocks server"
  echo "  3  HTTP call no timeout  requests.post() without timeout hangs"
  echo ""
  echo "Usage:"
  echo "  ./scripts/demo.sh bugfix <N>   Create the bug-fix PR"
  echo "  (merge it on GitHub)"
  echo "  ./scripts/demo.sh repeat <N>   Create the 'repeat mistake' PR"
  echo "  (run reviewers)"
  echo "  ./scripts/demo.sh reset        Wipe PRs and branches"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

cmd="${1:-help}"
num="${2:-0}"

case "$cmd" in
  bugfix)
    [[ "$num" -ge 1 && "$num" -le 3 ]] || fail "Usage: $0 bugfix <1|2|3>"
    ensure_clean
    "bugfix_${num}"
    ;;
  repeat)
    [[ "$num" -ge 1 && "$num" -le 3 ]] || fail "Usage: $0 repeat <1|2|3>"
    ensure_clean
    "repeat_${num}"
    ;;
  reset)
    do_reset
    ;;
  list)
    list_examples
    ;;
  *)
    list_examples
    ;;
esac
