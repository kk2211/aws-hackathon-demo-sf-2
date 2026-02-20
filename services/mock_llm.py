"""Mock OpenAI-style LLM service.

- gpt-50-mini: ignores the `temperature` parameter (always high variance).
- gpt-50: respects the `temperature` parameter (low variance when temp is low).
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


def complete(model: str, prompt: str, temperature: float = 0.7) -> dict:
    """Simulate an LLM completion call.

    Returns a dict shaped like a simplified OpenAI response.
    """
    # Simulate latency
    time.sleep(random.uniform(0.05, 0.15))

    if model == "gpt-50-mini":
        # BUG PATH: ignores temperature — always picks randomly (high variance)
        text = random.choice(SAMPLE_RECOMMENDATIONS)
    elif model == "gpt-50":
        # Correct path: low temperature → deterministic (pick first), high → random
        if temperature < 0.3:
            text = SAMPLE_RECOMMENDATIONS[0]
        else:
            text = random.choice(SAMPLE_RECOMMENDATIONS)
    else:
        raise ValueError(f"Unknown model: {model}")

    return {
        "model": model,
        "temperature_requested": temperature,
        "choices": [{"text": text}],
    }
