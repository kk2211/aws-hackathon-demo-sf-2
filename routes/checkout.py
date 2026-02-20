"""Bug 3 — HTTP Call Without Timeout (/checkout)

Uses requests.post() to the fraud API without a timeout parameter.
When the fraud API hangs, all workers block indefinitely.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer
import requests as http_requests

from config import FRAUD_API_URL

bp = Blueprint("checkout", __name__)


@bp.route("/checkout", methods=["POST"])
def checkout():
    data = request.get_json(force=True)
    order = {
        "order_id": data.get("order_id", "ORD-001"),
        "amount": data.get("amount", 99.99),
        "items": data.get("items", []),
    }

    with tracer.trace("http.fraud_check", service="acme-order-service", resource="checkout") as span:
        span.set_tag("order.id", order["order_id"])
        span.set_tag("order.amount", order["amount"])

        # BUG: no timeout — if fraud API hangs, this blocks forever
        resp = http_requests.post(FRAUD_API_URL, json=order)
        fraud_result = resp.json()

        span.set_tag("fraud.approved", fraud_result.get("approved"))
        span.set_tag("fraud.risk_score", fraud_result.get("risk_score"))

    if not fraud_result.get("approved"):
        return jsonify({"status": "rejected", "reason": "fraud_check_failed"}), 400

    return jsonify({"status": "confirmed", "order": order, "fraud": fraud_result})
