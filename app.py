"""acme-order-service — Flask app with Datadog APM instrumentation."""

import os
import sqlite3
import random

from flask import Flask, jsonify, request

from config import DB_PATH
from services.mock_fraud import check_fraud
from services.mock_email import send_email


def seed_database():
    """Create the products table and seed it with sample data if empty."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category TEXT NOT NULL,
            price REAL NOT NULL,
            description TEXT
        )
    """)

    count = conn.execute("SELECT COUNT(*) FROM products").fetchone()[0]
    if count == 0:
        products = [
            ("Wireless Headphones", "Electronics", 79.99, "Premium over-ear wireless headphones with noise cancellation"),
            ("Leather Weekend Bag", "Accessories", 149.99, "Handcrafted full-grain leather weekend travel bag"),
            ("Organic Coffee Sampler", "Food & Drink", 34.99, "Set of 6 single-origin organic coffee beans"),
            ("Running Shoes Pro", "Footwear", 129.99, "Lightweight performance running shoes with carbon plate"),
            ("Smart Home Starter Kit", "Electronics", 199.99, "Hub + 4 smart bulbs + 2 smart plugs + motion sensor"),
            ("Bluetooth Speaker", "Electronics", 59.99, "Waterproof portable Bluetooth speaker, 20hr battery"),
            ("Stainless Steel Water Bottle", "Accessories", 24.99, "32oz vacuum insulated stainless steel bottle"),
            ("Artisan Chocolate Gift Box", "Food & Drink", 44.99, "12-piece handmade Belgian chocolate assortment"),
            ("Yoga Mat Premium", "Fitness", 69.99, "6mm eco-friendly natural rubber yoga mat"),
            ("Mechanical Keyboard", "Electronics", 89.99, "Compact 75% mechanical keyboard with hot-swap switches"),
            ("Cotton Hoodie", "Apparel", 54.99, "Heavyweight 400gsm organic cotton pullover hoodie"),
            ("Cast Iron Skillet", "Kitchen", 39.99, "12-inch pre-seasoned cast iron skillet"),
            ("Desk Lamp LED", "Office", 45.99, "Adjustable LED desk lamp with wireless charging base"),
            ("Trail Mix Variety Pack", "Food & Drink", 19.99, "8 packs of premium nut and dried fruit trail mix"),
            ("Sunglasses Polarized", "Accessories", 64.99, "UV400 polarized aviator sunglasses with case"),
        ]
        conn.executemany(
            "INSERT INTO products (name, category, price, description) VALUES (?, ?, ?, ?)",
            products,
        )
        conn.commit()
    conn.close()


def seed_redis_sessions():
    """Seed Redis with sample session keys so /sessions has data to scan."""
    try:
        import redis
        from config import REDIS_HOST, REDIS_PORT

        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
        r.ping()

        existing = r.exists("session:seed_done")
        if not existing:
            for i in range(500):
                r.set(f"session:user_{i}", f'{{"user_id": {i}, "cart_items": {random.randint(0, 10)}}}', ex=3600)
            r.set("session:seed_done", "1", ex=3600)
    except Exception:
        # Redis not available — sessions endpoint will fail gracefully
        pass


def create_app():
    app = Flask(__name__)

    # Seed data
    seed_database()
    seed_redis_sessions()

    # Register route blueprints
    from routes.recommend import bp as recommend_bp
    from routes.sessions import bp as sessions_bp
    from routes.checkout import bp as checkout_bp
    from routes.search import bp as search_bp
    from routes.notify import bp as notify_bp
    from routes.generate_description import bp as generate_description_bp

    app.register_blueprint(recommend_bp)
    app.register_blueprint(sessions_bp)
    app.register_blueprint(checkout_bp)
    app.register_blueprint(search_bp)
    app.register_blueprint(notify_bp)
    app.register_blueprint(generate_description_bp)

    # --- Internal mock endpoints (called by routes via HTTP) ---

    @app.route("/_mock/fraud", methods=["POST"])
    def mock_fraud_endpoint():
        order = request.get_json(force=True)
        result = check_fraud(order)
        return jsonify(result)

    @app.route("/_mock/email", methods=["POST"])
    def mock_email_endpoint():
        data = request.get_json(force=True)
        try:
            result = send_email(
                to=data.get("to", ""),
                subject=data.get("subject", ""),
                body=data.get("body", ""),
            )
            return jsonify(result)
        except ConnectionError as exc:
            return jsonify({"error": str(exc)}), 503

    # --- Health check ---

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "ok", "service": "acme-order-service"})

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5000, debug=True)
