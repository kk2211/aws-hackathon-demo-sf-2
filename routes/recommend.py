"""Product recommendation endpoint (/recommend)

Uses the configured LLM model to generate personalized product recommendations.
"""

from flask import Blueprint, request, jsonify
from ddtrace import tracer

from services.mock_llm import complete
from config import LLM_MODEL

bp = Blueprint("recommend", __name__)


@bp.route("/recommend", methods=["POST"])
def recommend():
    data = request.get_json(force=True)
    prompt = data.get("prompt", "Recommend a product for this customer.")
    temperature = data.get("temperature", 0.2)

    with tracer.trace("llm.complete", service="acme-order-service", resource="recommend") as span:
        span.set_tag("llm.model", LLM_MODEL)
        span.set_tag("llm.temperature_requested", temperature)

        # BUG: gpt-50-mini ignores temperature → high variance output
        result = complete(model=LLM_MODEL, prompt=prompt, temperature=temperature)

        span.set_tag("llm.response_text", result["choices"][0]["text"])

    return jsonify(result)
