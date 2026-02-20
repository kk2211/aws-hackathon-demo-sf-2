"""Mock external fraud-check API.

By default responds in ~200ms. When FRAUD_API_HANG=true is set, hangs for 60s
to simulate an outage (triggers the no-timeout bug).
"""

import os
import time
import random


# Toggle: set FRAUD_API_HANG=true to simulate an outage
_hang = os.environ.get("FRAUD_API_HANG", "false").lower() == "true"


def check_fraud(order: dict) -> dict:
    """Simulate a fraud-check call."""
    if _hang:
        # Simulate a hung upstream service
        time.sleep(60)

    # Normal latency
    time.sleep(random.uniform(0.1, 0.3))

    risk_score = random.uniform(0, 1)
    return {
        "approved": risk_score < 0.85,
        "risk_score": round(risk_score, 3),
        "order_id": order.get("order_id"),
    }
