"""Bug 4 — Unbounded SQL Query (/search)

Uses SELECT * ... LIKE '%query%' without a LIMIT clause,
scanning the entire products table on every request.
"""

import sqlite3

from flask import Blueprint, request, jsonify
from ddtrace import tracer

from config import DB_PATH

bp = Blueprint("search", __name__)


def _get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


@bp.route("/search", methods=["GET"])
def search():
    q = request.args.get("q", "")
    if not q:
        return jsonify({"error": "missing query parameter 'q'"}), 400

    with tracer.trace("sqlite.query", service="acme-order-service", resource="search") as span:
        span.set_tag("search.query", q)

        db = _get_db()
        # BUG: no LIMIT — scans entire table, returns unbounded results
        cursor = db.execute(
            "SELECT * FROM products WHERE name LIKE ?", (f"%{q}%",)
        )
        rows = [dict(row) for row in cursor.fetchall()]
        db.close()

        span.set_tag("search.result_count", len(rows))

    return jsonify({"query": q, "count": len(rows), "products": rows})
