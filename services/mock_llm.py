"""Mock OpenAI-style LLM service.

Simulates completion calls for supported models (gpt-5, gpt-5-mini).
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

SUPPORTED_MODELS = ["gpt-5", "gpt-5-mini"]


def complete(model: str, prompt: str, temperature: float = 0.7) -> dict:
    """Simulate an LLM completion call.

    Returns a dict shaped like a simplified OpenAI response.
    """
    if model not in SUPPORTED_MODELS:
        raise ValueError(f"Unknown model: {model}")

    # Simulate latency
    time.sleep(random.uniform(0.05, 0.15))

    if temperature < 0.3:
        text = SAMPLE_RECOMMENDATIONS[0]
    else:
        text = random.choice(SAMPLE_RECOMMENDATIONS)

    return {
        "model": model,
        "temperature_requested": temperature,
        "choices": [{"text": text}],
    }
