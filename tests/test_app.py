import pytest
from fastapi.testclient import TestClient

from app.db import Job, Session
from app.main import app
from app.tasks import predict


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


@pytest.mark.parametrize("features", [[1, 2], [1, 2, 3, 4, 5], [-1, 2, 3, 4], [0, 2, 3, 4], [21, 2, 3, 4], ["bad", 2, 3, 4]])
def test_invalid_input(client, features):
    assert client.post("/jobs", json={"features": features}).status_code == 422


def test_health_and_unknown_job(client):
    assert client.get("/health").status_code == 200
    assert client.get("/jobs/00000000-0000-0000-0000-000000000001").status_code == 404
    assert client.get("/jobs/not-a-uuid").status_code == 422


def test_real_model_job_lifecycle(client, monkeypatch, trained_model):
    queued = []

    def enqueue(args, task_id):
        # The DB transaction must be visible before enqueue.
        with Session() as db:
            assert db.get(Job, task_id).status == "queued"
        queued.append(args[0])

    monkeypatch.setattr(predict, "apply_async", enqueue)
    response = client.post("/jobs", json={"features": [5.1, 3.5, 1.4, 0.2]})
    assert response.status_code == 202
    job_id = response.json()["id"]
    assert queued == [job_id]
    predict.run(job_id)  # Actual worker logic and actual MLflow-registered model.
    job = client.get("/jobs/" + job_id).json()
    assert job["status"] == "succeeded"
    assert job["result"]["class_name"] == "setosa"
    assert job["result"]["model_version"] == "1"
    predict.run(job_id)  # Redelivery of completed jobs is safe.
    assert client.get("/jobs/" + job_id).json() == job
    metrics = client.get("/metrics").text
    assert 'prediction_jobs{status="succeeded"} 1' in metrics
    assert "/jobs/{job_id}" in metrics
    assert job_id not in metrics  # No unbounded job-ID metric labels.


def test_broker_failure_persists_failure(client, monkeypatch):
    def fail(**kwargs):
        raise ConnectionError("broker down")
    monkeypatch.setattr(predict, "apply_async", fail)
    response = client.post("/jobs", json={"features": [5.1, 3.5, 1.4, 0.2]})
    assert response.status_code == 503
    job = client.get("/jobs/" + response.json()["detail"]["job_id"]).json()
    assert job["status"] == "failed"
    assert job["error"] == "enqueue_failed"


def test_model_failure_persists_failure(client, monkeypatch):
    from app import tasks
    monkeypatch.setattr(predict, "apply_async", lambda **kwargs: None)
    class UnavailableRegistry:
        def get_model_version_by_alias(self, *args):
            raise ConnectionError("private dependency detail")
    monkeypatch.setattr(tasks, "MlflowClient", UnavailableRegistry)
    job_id = client.post("/jobs", json={"features": [5.1, 3.5, 1.4, 0.2]}).json()["id"]
    with pytest.raises(ConnectionError):
        predict.run(job_id)
    job = client.get("/jobs/" + job_id).json()
    assert job["status"] == "failed"
    assert job["error"] == "ConnectionError"
