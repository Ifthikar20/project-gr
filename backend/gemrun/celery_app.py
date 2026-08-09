"""Celery app for background gem stocking (tier 12k+; docs/20).

This is imported ONLY by the Celery worker process, never by the Django web
process (runserver/gunicorn), so enabling Celery adds no import cost or
dependency to serving requests. Start the worker with:

    GEMRUN_STOCKING_BACKEND=celery GEMRUN_CELERY_BROKER=redis://redis:6379/1 \
        celery -A gemrun.celery_app worker -l info

and set the same two env vars on the web process so it enqueues instead of
using the in-process thread pool.
"""
import os

from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "gemrun.settings")

app = Celery("gemrun")
# CELERY_* settings (e.g. CELERY_BROKER_URL) come from Django settings.
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks(["api"])
