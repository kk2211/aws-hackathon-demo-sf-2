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

    with tracer.trace("llm.complete", service="acme-order-service", resource="recommend") as span:
        span.set_tag("llm.model", LLM_MODEL)

        # gpt-5 does not support the temperature parameter — omit it
        result = complete(model=LLM_MODEL, prompt=prompt)

        span.set_tag("llm.response_text", result["choices"][0]["text"])

    return jsonify(result)
