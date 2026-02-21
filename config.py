import os

REDIS_HOST = os.environ.get("REDIS_HOST", "localhost")
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))

FRAUD_API_URL = os.environ.get("FRAUD_API_URL", "http://localhost:5000/_mock/fraud")
EMAIL_API_URL = os.environ.get("EMAIL_API_URL", "http://localhost:5000/_mock/email")
LLM_API_URL = os.environ.get("LLM_API_URL", "http://localhost:5000/_mock/llm")

LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-5")

DB_PATH = os.environ.get("DB_PATH", "products.db")
