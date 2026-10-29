from contextlib import asynccontextmanager
from time import monotonic
from uuid import UUID, uuid4

from fastapi import FastAPI, HTTPException, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import func, select, text

from app.db import Base, Job, Session, engine
from app.tasks import predict

REQUESTS = Counter("api_requests_total", "API requests", ["method", "path", "status"])
LATENCY = Histogram("api_request_seconds", "API latency", ["path"])


@asynccontextmanager
async def lifespan(app):
    # Tiny demo schema; production uses a separate Alembic migration job.
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="Mini MLOps: Iris", lifespan=lifespan)


class PredictionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    features: list[float] = Field(min_length=4, max_length=4)

    @field_validator("features")
    @classmethod
    def valid_measurements(cls, values):
        if any(not 0 < value <= 20 for value in values):
            raise ValueError("Each measurement must be finite, greater than 0 and at most 20 cm")
        return values


@app.middleware("http")
async def metrics(request, call_next):
    start = monotonic()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = getattr(route, "path", "unmatched")
        if path != "/metrics":
            REQUESTS.labels(request.method, path, str(status)).inc()
            LATENCY.labels(path).observe(monotonic() - start)


@app.get("/health")
def health():
    with Session() as db:
        db.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/jobs", status_code=202)
def submit(payload: PredictionInput):
    job_id = str(uuid4())
    with Session() as db:
        db.add(Job(id=job_id, features=payload.features, status="queued"))
        db.commit()  # Commit before enqueue so workers can see the row.
    try:
        predict.apply_async(args=[job_id], task_id=job_id)
    except Exception:
        with Session() as db:
            job = db.get(Job, job_id)
            job.status = "failed"
            job.error = "enqueue_failed"
            db.commit()
        raise HTTPException(503, detail={"error": "queue unavailable", "job_id": job_id})
    return {"id": job_id, "status": "queued"}


@app.get("/jobs/{job_id}")
def get_job(job_id: UUID):
    with Session() as db:
        job = db.get(Job, str(job_id))
        if job is None:
            raise HTTPException(404, "Job not found")
        return {"id": job.id, "status": job.status, "result": job.result, "error": job.error}


@app.get("/metrics", include_in_schema=False)
def prometheus_metrics():
    # Read persistent counts from PostgreSQL: includes worker results and survives API restarts.
    with Session() as db:
        counts = dict(db.execute(select(Job.status, func.count()).group_by(Job.status)).all())
    extra = '# HELP prediction_jobs Current persisted jobs by status\n# TYPE prediction_jobs gauge\n'
    for status in ("queued", "running", "succeeded", "failed"):
        extra += f'prediction_jobs{{status="{status}"}} {counts.get(status, 0)}\n'
    return Response(generate_latest() + extra.encode(), headers={"Content-Type": CONTENT_TYPE_LATEST})
