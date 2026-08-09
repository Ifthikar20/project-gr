# Production image for the GemRun API. Dev/CI don't need this — they run
# `manage.py runserver` on SQLite. Build context is backend/.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# psycopg[binary], cryptography, and gunicorn all ship manylinux wheels, so
# no system build toolchain is needed.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

# Multi-worker WSGI server (worker count is computed in gunicorn.conf.py).
CMD ["gunicorn", "-c", "gunicorn.conf.py", "gemrun.wsgi:application"]
