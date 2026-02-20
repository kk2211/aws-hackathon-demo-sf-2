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
