FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Seed the SQLite database at build time
RUN python -c "from app import seed_database; seed_database()"

EXPOSE 5000

# Use ddtrace-run to auto-instrument the app with Datadog APM
CMD ["ddtrace-run", "gunicorn", "--bind", "0.0.0.0:5000", "--workers", "4", "--timeout", "120", "wsgi:application"]
