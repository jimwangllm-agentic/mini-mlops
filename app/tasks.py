import os
from functools import lru_cache

import mlflow.sklearn
from celery import Celery
from mlflow import MlflowClient

from app.db import Job, Session

celery = Celery("iris", broker=os.getenv("REDIS_URL", "redis://redis:6379/0"))
celery.conf.update(
    task_ignore_result=True,  # PostgreSQL is the single source of job results.
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1,
    broker_connection_retry_on_startup=True,
    task_publish_retry=False,  # Return a clear 503 if the broker is unavailable.
)


@lru_cache(maxsize=8)
def load_model(version: str):
    return mlflow.sklearn.load_model(f"models:/iris/{version}")


@celery.task(name="predict")
def predict(job_id: str):
    with Session() as db:
        job = db.get(Job, job_id)
        if job is None or job.status in ("succeeded", "failed"):
            return
        features = job.features
        job.status = "running"
        db.commit()
    try:
        # Resolve the alias each job, then cache by immutable version.
        version = MlflowClient().get_model_version_by_alias("iris", "champion").version
        model = load_model(version)
        label = int(model.predict([features])[0])
        result = {
            "class_id": label,
            "class_name": ["setosa", "versicolor", "virginica"][label],
            "model_version": str(version),
        }
    except Exception as exc:
        with Session() as db:
            job = db.get(Job, job_id)
            job.status = "failed"
            job.error = type(exc).__name__  # Don't expose dependency credentials.
            db.commit()
        raise
    with Session() as db:
        job = db.get(Job, job_id)
        job.status = "succeeded"
        job.result = result
        db.commit()
