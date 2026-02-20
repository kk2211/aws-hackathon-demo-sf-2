"""Active sessions endpoint (/sessions)

Lists currently active user sessions stored in Redis.
"""

from flask import Blueprint, jsonify
from ddtrace import tracer
import redis as redis_lib

from config import REDIS_HOST, REDIS_PORT

bp = Blueprint("sessions", __name__)

_redis = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


@bp.route("/sessions", methods=["GET"])
def list_sessions():
    with tracer.trace("redis.scan", service="acme-order-service", resource="sessions") as span:
        # Use SCAN instead of KEYS — non-blocking, cursor-based iteration
        keys = list(_redis.scan_iter("session:*", count=100))
        span.set_tag("redis.command", "SCAN session:*")
        span.set_tag("redis.key_count", len(keys))

    sessions = []
    for key in keys[:100]:  # cap response size
        data = _redis.get(key)
        if data:
            sessions.append({"key": key, "data": data})

    return jsonify({"count": len(sessions), "sessions": sessions})
