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
#   1  GPT-5 temperature error   (gpt-5 doesn't support temperature parameter)
#   2  HTTP call no timeout      (requests.post() without timeout)

set -euo pipefail

REPO="kk2211/aws-hackathon-demo-sf"

# Branch names per example
BUGFIX_BRANCHES=( "" "fix/llm-model-temperature" "fix/checkout-timeout" )
REPEAT_BRANCHES=( "" "feat/generate-description" "feat/refund-endpoint" )

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
  # Example 1: Fix gpt-5 temperature error — remove temperature from complete() call
  local branch="${BUGFIX_BRANCHES[1]}"
  info "Creating bugfix PR: Remove temperature parameter for gpt-5..."

  create_branch_from_main "$branch"

  # Fix recommend.py: remove temperature from the LLM API call
  cat > routes/recommend.py <<'PYEOF'
"""Product recommendation endpoint (/recommend)

Uses the configured LLM model to generate personalized product recommendations.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer
import requests as http_requests

from config import LLM_MODEL, LLM_API_URL

bp = Blueprint("recommend", __name__)


@bp.route("/recommend", methods=["POST"])
def recommend():
    data = request.get_json(force=True)
    prompt = data.get("prompt", "Recommend a product for this customer.")

    with tracer.trace("llm.complete", service="acme-order-service", resource="recommend") as span:
        span.set_tag("llm.model", LLM_MODEL)

        # gpt-5 does not support the temperature parameter — omit it
        resp = http_requests.post(LLM_API_URL, json={
            "model": LLM_MODEL,
            "prompt": prompt,
        })

        if resp.status_code != 200:
            error_detail = resp.json().get("error", {}).get("message", "LLM API error")
            span.set_tag("error", True)
            span.set_tag("error.message", error_detail)
            return jsonify({"error": error_detail}), resp.status_code

        result = resp.json()
        span.set_tag("llm.response_text", result["choices"][0]["text"])

    return jsonify(result)
PYEOF

  git add routes/recommend.py
  git commit -m "$(cat <<'EOF'
fix: remove temperature parameter from /recommend for gpt-5 compatibility

gpt-5 does not support the temperature parameter — passing any value
other than the default (1.0) causes a ValueError. After upgrading from
gpt-4o to gpt-5, every /recommend call was failing with:

  "'temperature' does not support 0.2 with model gpt-5"

Removed the temperature parameter from the complete() call since
gpt-5 only supports the default value.
EOF
)"

  git push -u origin "$branch"

  gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Fix /recommend crash: gpt-5 does not support temperature parameter" \
    --body "$(cat <<'EOF'
## Summary
- After upgrading LLM from `gpt-4o` to `gpt-5`, every `/recommend` request started failing with a `ValueError`
- Investigated via Datadog APM — error traces showed `ValueError: 'temperature' does not support 0.2 with model gpt-5. Only the default (1) value is supported.`
- Root cause: GPT-5 models removed support for the `temperature` parameter. Our code was still passing `temperature=0.2`
- Fix: Removed the temperature parameter from the `complete()` call

## Datadog evidence
- Service: `acme-order-service`, env: `demo`
- APM Traces → filter by resource `/recommend` → 100% error rate
- Error: `ValueError: 'temperature' does not support 0.2 with model gpt-5`

## Test plan
- [ ] Hit `/recommend` — should return recommendations without errors
- [ ] Verify Datadog traces show successful `llm.complete` spans
EOF
)"

  git checkout main
  ok "Bugfix PR created for example 1"
}

bugfix_2() {
  # Example 2: Fix missing timeout on requests.post()
  local branch="${BUGFIX_BRANCHES[2]}"
  info "Creating bugfix PR: Add HTTP timeout to /checkout..."

  create_branch_from_main "$branch"

  # Fix checkout.py: add timeout
  sed -i '' 's|resp = http_requests.post(FRAUD_API_URL, json=order)$|resp = http_requests.post(FRAUD_API_URL, json=order, timeout=5)|' routes/checkout.py

  git add routes/checkout.py
  git commit -m "$(cat <<'EOF'
fix: add 5s timeout to fraud API call in /checkout

requests.post() to the fraud-check API had no timeout parameter.
When the fraud API hangs, all gunicorn workers block indefinitely,
causing 504 errors across all endpoints.
EOF
)"

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
  ok "Bugfix PR created for example 2"
}

# ─── Repeat PRs (same mistake, different code) ───────────────────────────────

repeat_1() {
  # Example 1: New endpoint that passes temperature to gpt-5
  local branch="${REPEAT_BRANCHES[1]}"
  info "Creating repeat PR: New /generate-description endpoint passing temperature to gpt-5..."

  create_branch_from_main "$branch"

  # Create new route file
  cat > routes/generate_description.py <<'PYEOF'
"""Product description generator (/generate-description)

Uses the LLM to generate marketing descriptions for products.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer
import requests as http_requests

from config import LLM_API_URL

bp = Blueprint("generate_description", __name__)


@bp.route("/generate-description", methods=["POST"])
def generate_description():
    data = request.get_json(force=True)
    product = data.get("product", "product")
    tone = data.get("tone", "professional")

    prompt = f"Write a {tone} marketing description for: {product}"

    with tracer.trace("llm.complete", service="acme-order-service", resource="generate_description") as span:
        span.set_tag("llm.model", "gpt-5")
        span.set_tag("llm.prompt_length", len(prompt))

        # Use low temperature for consistent, high-quality output
        resp = http_requests.post(LLM_API_URL, json={
            "model": "gpt-5",
            "prompt": prompt,
            "temperature": 0.1,
        })

        if resp.status_code != 200:
            error_detail = resp.json().get("error", {}).get("message", "LLM API error")
            span.set_tag("error", True)
            span.set_tag("error.message", error_detail)
            return jsonify({"error": error_detail}), resp.status_code

        result = resp.json()
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
  git commit -m "$(cat <<'EOF'
feat: add /generate-description endpoint for product marketing copy

New endpoint that generates product descriptions using the LLM.
Supports configurable tone (professional, casual, etc.) and uses
low temperature for consistent output.
EOF
)"

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
  # Example 2: New endpoint with requests.post() and no timeout
  local branch="${REPEAT_BRANCHES[2]}"
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
  git commit -m "$(cat <<'EOF'
feat: add /refund endpoint for processing customer refunds

New endpoint that processes refund requests by validating them
through the fraud/risk API before approving.
EOF
)"

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
  ok "Repeat PR created for example 2"
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

  # Revert all merged demo PRs on main (bugfix + repeat branches)
  git checkout main 2>/dev/null || true
  git pull origin main --quiet 2>/dev/null || true

  for branch in "${ALL_BRANCHES[@]}"; do
    merge_sha=$(gh pr list --repo "$REPO" --head "$branch" --state merged \
      --json mergeCommit --jq '.[0].mergeCommit.oid' 2>/dev/null || echo "")
    if [[ -n "$merge_sha" && "$merge_sha" != "null" ]]; then
      git revert -m 1 "$merge_sha" --no-edit 2>/dev/null && ok "Reverted merged PR: $branch ($merge_sha)" || true
    fi
  done

  # Push reverts to main
  git push origin main 2>/dev/null || true

  # Delete remote branches
  for branch in "${ALL_BRANCHES[@]}"; do
    git push origin --delete "$branch" 2>/dev/null && ok "Deleted remote: $branch" || true
  done

  # Delete local branches
  for branch in "${ALL_BRANCHES[@]}"; do
    git branch -D "$branch" 2>/dev/null && ok "Deleted local: $branch" || true
  done

  # Sync local main with origin
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
  echo "  1  GPT-5 temperature error   gpt-5 doesn't support temperature — causes ValueError"
  echo "  2  HTTP call no timeout      requests.post() without timeout hangs workers"
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
    [[ "$num" -ge 1 && "$num" -le 2 ]] || fail "Usage: $0 bugfix <1|2>"
    ensure_clean
    "bugfix_${num}"
    ;;
  repeat)
    [[ "$num" -ge 1 && "$num" -le 2 ]] || fail "Usage: $0 repeat <1|2>"
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
