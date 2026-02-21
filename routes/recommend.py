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
