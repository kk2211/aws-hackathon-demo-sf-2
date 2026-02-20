"""Mock email / notification service.

Fails ~80% of the time to simulate a flaky upstream, which triggers the
retry-storm bug in the /notify endpoint.
"""

import random
import time


def send_email(to: str, subject: str, body: str) -> dict:
    """Simulate sending an email. Returns success/failure dict."""
    time.sleep(random.uniform(0.05, 0.15))

    if random.random() < 0.80:
        # 80% failure rate
        raise ConnectionError("mock email service unavailable")

    return {"status": "sent", "to": to, "subject": subject}
