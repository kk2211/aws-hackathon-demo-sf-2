"""Mock OpenAI-style LLM service.

Simulates completion calls for supported models (gpt-4o, gpt-5).

gpt-4o supports the temperature parameter.
gpt-5 does NOT support temperature — raises ValueError if temperature != 1.0.
This mirrors the real OpenAI GPT-5 API behavior.
"""

import random
import time

SAMPLE_RECOMMENDATIONS = [
    "Try our premium wireless headphones — top rated this month.",
    "Customers who bought this also loved the leather weekend bag.",
    "Based on your history, we recommend the organic coffee sampler.",
    "Our best-selling running shoes are 20% off this week.",
    "You might enjoy the new smart home starter kit.",
    "The portable Bluetooth speaker is perfect for your next trip.",
    "Check out the stainless-steel water bottle — a customer favorite.",
    "Our artisan chocolate gift box makes a great present.",
]

SUPPORTED_MODELS = ["gpt-4o", "gpt-5"]


def complete(model: str, prompt: str, temperature: float = 1.0) -> dict:
    """Simulate an LLM completion call.

    Returns a dict shaped like a simplified OpenAI response.
    """
    if model not in SUPPORTED_MODELS:
        raise ValueError(f"Unknown model: {model}")

    # Simulate latency
    time.sleep(random.uniform(0.05, 0.15))

    if model == "gpt-5":
        # gpt-5 does not support temperature — only default (1.0) is allowed
        if temperature != 1.0:
            raise ValueError(
                f"'temperature' does not support {temperature} with model gpt-5. "
                "Only the default (1) value is supported."
            )
        text = random.choice(SAMPLE_RECOMMENDATIONS)
    else:
        # gpt-4o respects temperature
        if temperature < 0.3:
            text = SAMPLE_RECOMMENDATIONS[0]
        else:
            text = random.choice(SAMPLE_RECOMMENDATIONS)

    return {
        "model": model,
        "temperature_requested": temperature,
        "choices": [{"text": text}],
    }
