"""Celery tasks for background gem stocking (tier 12k+; docs/20).

Only imported when GEMRUN_STOCKING_BACKEND=celery — the default "thread"
backend never touches this module, so Celery isn't a hard dependency of the
web process. Run the worker with:

    celery -A gemrun.celery_app worker -l info
"""
from celery import shared_task
from django.db import close_old_connections

from . import system_drops


@shared_task(name="api.rotate_and_top_up", ignore_result=True)
def rotate_and_top_up_task(lat, lng):
    """Restock/rotate one mile — the same pass the thread pool runs, moved
    onto the shared queue so multiple app boxes don't each duplicate the
    Overpass fetch + placement. close_old_connections brackets it because a
    long-lived worker must not reuse a stale DB connection between tasks."""
    try:
        close_old_connections()
        system_drops.rotate_and_top_up(
            lat, lng, budget_s=system_drops.BACKGROUND_BUDGET_S)
    finally:
        close_old_connections()
