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
