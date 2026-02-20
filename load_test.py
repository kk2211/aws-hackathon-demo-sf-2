#!/usr/bin/env python3
"""Load-test script for acme-order-service.

Hits endpoints in a loop to generate visible Datadog APM data.

Usage:
    python load_test.py --endpoint /sessions --rps 10 --duration 60
    python load_test.py --all --rps 5 --duration 120
"""

import argparse
import json
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.request import urlopen, Request
from urllib.error import URLError


BASE_URL = "http://localhost:5000"

ENDPOINTS = {
    "/recommend": {
        "method": "POST",
        "body": {"prompt": "Suggest a product", "temperature": 0.2},
    },
    "/sessions": {
        "method": "GET",
        "body": None,
    },
    "/checkout": {
        "method": "POST",
        "body": {
            "order_id": "ORD-{rand}",
            "amount": 99.99,
            "items": [{"sku": "SKU-001", "qty": 1}],
        },
    },
    "/search": {
        "method": "GET",
        "params": {"q": random.choice(["shoe", "coffee", "leather", "smart", "kit"])},
        "body": None,
    },
    "/notify": {
        "method": "POST",
        "body": {
            "to": "test@example.com",
            "subject": "Order Confirmed",
            "body": "Thanks for your order!",
        },
    },
}


_base_url = BASE_URL


def make_request(endpoint: str) -> dict:
    """Fire a single request and return status info."""
    cfg = ENDPOINTS[endpoint]
    method = cfg["method"]
    url = _base_url + endpoint

    if method == "GET" and cfg.get("params"):
        qs = "&".join(f"{k}={v}" for k, v in cfg["params"].items())
        url += f"?{qs}"

    body_data = None
    if cfg["body"]:
        payload = json.loads(json.dumps(cfg["body"]).replace("{rand}", str(random.randint(1000, 9999))))
        body_data = json.dumps(payload).encode()

    req = Request(url, data=body_data, method=method)
    if body_data:
        req.add_header("Content-Type", "application/json")

    start = time.time()
    try:
        resp = urlopen(req, timeout=90)
        elapsed = time.time() - start
        return {"endpoint": endpoint, "status": resp.status, "time_ms": round(elapsed * 1000), "ok": True}
    except URLError as e:
        elapsed = time.time() - start
        return {"endpoint": endpoint, "status": getattr(e, "code", 0), "time_ms": round(elapsed * 1000), "ok": False, "error": str(e)}
    except Exception as e:
        elapsed = time.time() - start
        return {"endpoint": endpoint, "status": 0, "time_ms": round(elapsed * 1000), "ok": False, "error": str(e)}


def run_load_test(endpoints: list, rps: int, duration: int):
    """Run load against the specified endpoints."""
    interval = 1.0 / rps
    end_time = time.time() + duration
    total = 0
    errors = 0

    print(f"Load test: {rps} req/s for {duration}s against {', '.join(endpoints)}")
    print("-" * 60)

    with ThreadPoolExecutor(max_workers=min(rps * 2, 50)) as pool:
        while time.time() < end_time:
            endpoint = random.choice(endpoints)
            future = pool.submit(make_request, endpoint)
            result = future.result()

            total += 1
            status_str = f"{result['status']}"
            if not result["ok"]:
                errors += 1
                status_str = f"{result['status']} ERR"

            print(f"  [{total:>5}] {result['endpoint']:<15} {status_str:<8} {result['time_ms']:>6}ms")

            time.sleep(interval)

    print("-" * 60)
    print(f"Done. {total} requests, {errors} errors ({errors/max(total,1)*100:.1f}% error rate)")


def main():
    parser = argparse.ArgumentParser(description="Load-test acme-order-service")
    parser.add_argument("--endpoint", type=str, help="Single endpoint to test (e.g. /sessions)")
    parser.add_argument("--all", action="store_true", help="Test all endpoints")
    parser.add_argument("--rps", type=int, default=5, help="Requests per second (default: 5)")
    parser.add_argument("--duration", type=int, default=60, help="Duration in seconds (default: 60)")
    parser.add_argument("--base-url", type=str, default=BASE_URL, help="Base URL (default: http://localhost:5000)")

    args = parser.parse_args()

    global _base_url
    _base_url = args.base_url

    if args.all:
        endpoints = list(ENDPOINTS.keys())
    elif args.endpoint:
        if args.endpoint not in ENDPOINTS:
            print(f"Unknown endpoint: {args.endpoint}")
            print(f"Available: {', '.join(ENDPOINTS.keys())}")
            sys.exit(1)
        endpoints = [args.endpoint]
    else:
        print("Specify --endpoint <path> or --all")
        sys.exit(1)

    run_load_test(endpoints, args.rps, args.duration)


if __name__ == "__main__":
    main()
