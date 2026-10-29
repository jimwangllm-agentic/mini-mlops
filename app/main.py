"""The HTTP front door: validate requests, queue predictions, and return saved results.

Interview reading order: PredictionInput -> submit -> get_job.
The actual model runs in app/tasks.py, outside this API process.
"""

from contextlib import asynccontextmanager
from time import monotonic
from uuid import UUID, uuid4

from fastapi import FastAPI, HTTPException, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import func, select, text

from app.db import Base, Job, Session, engine
from app.tasks import predict

# Prometheus reads these measurements through GET /metrics.
# Counter = number of requests; Histogram = distribution of response times.
REQUESTS = Counter("api_requests_total", "API requests", ["method", "path", "status"])
LATENCY = Histogram("api_request_seconds", "API latency", ["path"])


@asynccontextmanager
async def lifespan(app):
    """Create the job table before FastAPI begins accepting requests.

    FastAPI calls this once at process startup. Code before `yield` is startup;
    code after it would perform shutdown cleanup.
    """
    # Tiny demo schema; production uses a separate Alembic migration job.
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="Mini MLOps: Iris", lifespan=lifespan)


class PredictionInput(BaseModel):
    """Describe the accepted JSON body so Pydantic can validate it automatically.

    features = [sepal length, sepal width, petal length, petal width], in cm.
    FastAPI returns HTTP 422 if the body does not match this schema.
    """

    # Swagger displays a valid flower example instead of generating four zeros.
    # This is documentation, not a default: requests must still provide features.
    model_config = ConfigDict(
        extra="forbid",
        json_schema_extra={"example": {"features": [5.1, 3.5, 1.4, 0.2]}},
    )
    features: list[float] = Field(
        min_length=4,
        max_length=4,
        description="Sepal length, sepal width, petal length, petal width, in centimeters.",
    )

    @field_validator("features")
    @classmethod
    def valid_measurements(cls, values):
        """Reject zero, negative, oversized, NaN, or infinite measurements.

        Pydantic calls this validator after parsing the features list.
        Returning values accepts them; raising ValueError rejects the request.
        """
        if any(not 0 < value <= 20 for value in values):
            raise ValueError("Each measurement must be finite, greater than 0 and at most 20 cm")
        return values


@app.middleware("http")
async def metrics(request, call_next):
    """Measure each HTTP request as it passes through the API.

    `call_next` runs the requested endpoint. The finally block records the
    status and elapsed time even when the endpoint raises an exception.
    This measures API response time, not background prediction completion time.
    """
    start = monotonic()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        # Label by /jobs/{job_id}, rather than each individual UUID, to avoid
        # creating a separate time series for every user's job.
        route = request.scope.get("route")
        path = getattr(route, "path", "unmatched")
        if path != "/metrics":
            REQUESTS.labels(request.method, path, str(status)).inc()
            LATENCY.labels(path).observe(monotonic() - start)


@app.get("/health")
def health():
    """Answer GET /health after checking that PostgreSQL can execute a query.

    Docker and Kubernetes use this as a readiness signal. It checks the API
    and database, not the queue, worker, or MLflow server.
    """
    with Session() as db:
        db.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/jobs", status_code=202)
def submit(payload: PredictionInput):
    """Accept POST /jobs, save the input, and enqueue its ID for a Celery worker.

    Input: a validated JSON body containing four measurements.
    Output: HTTP 202 with a UUID to poll. No model prediction happens here.
    """
    # 1. Create a unique ID and persist the input before a worker can read it.
    job_id = str(uuid4())
    with Session() as db:
        db.add(Job(id=job_id, features=payload.features, status="queued"))
        db.commit()  # Commit before enqueue so workers can see the row.
    try:
        # 2. Send a task message through Redis. apply_async queues work;
        # calling predict(job_id) directly would execute it in this API process.
        predict.apply_async(args=[job_id], task_id=job_id)
    except Exception:
        # 3a. If publishing fails, retain a failed record and return HTTP 503.
        with Session() as db:
            job = db.get(Job, job_id)
            job.status = "failed"
            job.error = "enqueue_failed"
            db.commit()
        raise HTTPException(503, detail={"error": "queue unavailable", "job_id": job_id})
    # 3b. Return immediately; the client can check this ID using GET /jobs/{id}.
    return {"id": job_id, "status": "queued"}


@app.get("/jobs/{job_id}")
def get_job(job_id: UUID):
    """Answer GET /jobs/{job_id} with the job's current saved status and result.

    FastAPI validates the UUID. Unknown IDs return HTTP 404. This function
    only reads PostgreSQL; it does not enqueue or repeat the prediction.
    """
    with Session() as db:
        job = db.get(Job, str(job_id))
        if job is None:
            raise HTTPException(404, "Job not found")
        return {"id": job.id, "status": job.status, "result": job.result, "error": job.error}


@app.get("/metrics", include_in_schema=False)
def prometheus_metrics():
    """Expose request metrics and durable job counts for Prometheus to scrape.

    Request counters/timings come from this API process. Job counts come from
    PostgreSQL, so worker updates are included and counts survive API restarts.
    """
    # Read persistent counts from PostgreSQL: includes worker results and survives API restarts.
    with Session() as db:
        counts = dict(db.execute(select(Job.status, func.count()).group_by(Job.status)).all())
    # Prometheus's text format uses HELP/TYPE lines followed by numeric samples.
    extra = '# HELP prediction_jobs Current persisted jobs by status\n# TYPE prediction_jobs gauge\n'
    for status in ("queued", "running", "succeeded", "failed"):
        extra += f'prediction_jobs{{status="{status}"}} {counts.get(status, 0)}\n'
    return Response(generate_latest() + extra.encode(), headers={"Content-Type": CONTENT_TYPE_LATEST})
