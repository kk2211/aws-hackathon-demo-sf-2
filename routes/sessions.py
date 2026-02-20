"""Bug 2 — Blocking Redis Command (/sessions)

Uses redis.keys("session:*") which is O(N) and blocks the
single-threaded Redis server, causing latency spikes.
"""

from flask import Blueprint, jsonify
from ddtrace import tracer
import redis as redis_lib

from config import REDIS_HOST, REDIS_PORT

bp = Blueprint("sessions", __name__)

_redis = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


@bp.route("/sessions", methods=["GET"])
def list_sessions():
    with tracer.trace("redis.keys", service="acme-order-service", resource="sessions") as span:
        # BUG: redis.keys() is O(N), blocks Redis for the entire scan
        keys = _redis.keys("session:*")
        span.set_tag("redis.command", "KEYS session:*")
        span.set_tag("redis.key_count", len(keys))

    sessions = []
    for key in keys[:100]:  # cap response size
        data = _redis.get(key)
        if data:
            sessions.append({"key": key, "data": data})

    return jsonify({"count": len(sessions), "sessions": sessions})
