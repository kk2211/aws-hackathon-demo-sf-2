"""Bug 5 — Retry Storm (/notify)

Retries up to 10 times with no backoff against a flaky email service,
hammering the downstream and amplifying failures.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer

from services.mock_email import send_email

bp = Blueprint("notify", __name__)

MAX_RETRIES = 10  # BUG: too many retries


@bp.route("/notify", methods=["POST"])
def notify():
    data = request.get_json(force=True)
    to = data.get("to", "customer@example.com")
    subject = data.get("subject", "Order Confirmation")
    body = data.get("body", "Your order has been placed.")

    last_error = None

    with tracer.trace("email.send", service="acme-order-service", resource="notify") as span:
        span.set_tag("email.to", to)
        span.set_tag("email.max_retries", MAX_RETRIES)

        for attempt in range(MAX_RETRIES):
            try:
                # BUG: no backoff between retries — hammers the service
                result = send_email(to=to, subject=subject, body=body)
                span.set_tag("email.attempts", attempt + 1)
                span.set_tag("email.status", "sent")
                return jsonify({"status": "sent", "attempts": attempt + 1, "result": result})
            except ConnectionError as exc:
                last_error = str(exc)
                span.set_tag(f"email.attempt_{attempt}_error", last_error)

        span.set_tag("email.status", "failed")
        span.set_tag("email.attempts", MAX_RETRIES)
        span.error = 1

    return jsonify({
        "status": "failed",
        "attempts": MAX_RETRIES,
        "error": last_error,
    }), 502
