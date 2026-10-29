"""The background worker's task: read a job, predict with MLflow, save its result.

Redis holds the task message. Celery receives it and calls predict(job_id).
PostgreSQL holds the input and output; the message only needs the job ID.
"""

import os
from functools import lru_cache

import mlflow.sklearn
from celery import Celery
from mlflow import MlflowClient

from app.db import Job, Session

# The API and worker share this Celery configuration and Redis broker address.
celery = Celery("iris", broker=os.getenv("REDIS_URL", "redis://redis:6379/0"))
celery.conf.update(
    task_ignore_result=True,  # PostgreSQL is the single source of job results.
    task_acks_late=True,  # Acknowledge after execution, allowing crash redelivery.
    task_reject_on_worker_lost=True,  # Requeue if a worker child process dies.
    worker_prefetch_multiplier=1,  # Reserve fewer tasks so workers share the queue.
    broker_connection_retry_on_startup=True,
    task_publish_retry=False,  # Return a clear 503 if the broker is unavailable.
)


@lru_cache(maxsize=8)
def load_model(version: str):
    """Download one registered Iris model version from MLflow.

    The lru_cache decorator remembers up to eight loaded versions per process,
    avoiding repeated downloads for predictions using the same model version.
    """
    return mlflow.sklearn.load_model(f"models:/iris/{version}")


# This decorator registers the function as a task Celery workers can execute.
@celery.task(name="predict")
def predict(job_id: str):
    """Process a queued prediction and store either a result or a failure.

    Input: the UUID published by FastAPI. The worker reads measurements from
    PostgreSQL, resolves MLflow's champion alias, runs inference, and saves the
    result with its model version. The client later reads that row via the API.
    """
    # 1. Read the job and make its running state visible to polling clients.
    with Session() as db:
        job = db.get(Job, job_id)
        if job is None or job.status in ("succeeded", "failed"):
            # Ignore missing jobs and redelivery of already completed jobs.
            return
        features = job.features
        job.status = "running"
        db.commit()
    try:
        # 2. Ask MLflow which immutable version currently has the champion alias.
        # Resolving each job lets a newly promoted model serve new predictions.
        version = MlflowClient().get_model_version_by_alias("iris", "champion").version
        model = load_model(version)
        # 3. sklearn expects a list of samples, so [features] wraps one flower
        # in a batch. [0] takes its prediction; int converts numpy's value to JSON.
        label = int(model.predict([features])[0])
        result = {
            "class_id": label,
            "class_name": ["setosa", "versicolor", "virginica"][label],
            "model_version": str(version),
        }
    except Exception as exc:
        # 4a. Persist a safe error category for the user, then raise so Celery
        # also records the full failure in its worker logs.
        with Session() as db:
            job = db.get(Job, job_id)
            job.status = "failed"
            job.error = type(exc).__name__  # Don't expose dependency credentials.
            db.commit()
        raise
    # 4b. On success, commit the result and model version to durable storage.
    with Session() as db:
        job = db.get(Job, job_id)
        job.status = "succeeded"
        job.result = result
        db.commit()
