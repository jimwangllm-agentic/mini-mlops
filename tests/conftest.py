import os
import tempfile
from pathlib import Path

import pytest

# Never point tests at the application DB. CI explicitly supplies a disposable DB.
scratch = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
os.environ["DATABASE_URL"] = os.getenv(
    "TEST_DATABASE_URL", "sqlite:///" + str(Path(scratch.name) / "jobs.db")
)
os.environ["MLFLOW_TRACKING_URI"] = "sqlite:///" + (Path(scratch.name) / "mlflow.db").as_posix()

from app.db import Base, engine  # noqa: E402


@pytest.fixture(autouse=True)
def clean_db():
    """Start each test with empty job tables in the disposable test database."""
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield


def pytest_sessionfinish(session, exitstatus):
    """Close pooled database connections when pytest finishes all tests."""
    engine.dispose()  # Release pooled SQLite handles on Windows.


@pytest.fixture(scope="session")
def trained_model():
    """Train/register a real model once, using a temporary MLflow database."""
    import mlflow
    from app.train import main

    # SQLite tracking keeps the test independent of an MLflow HTTP server.
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    client = mlflow.MlflowClient()
    client.create_experiment("iris-demo", artifact_location=(Path(scratch.name) / "artifacts").as_uri())
    main()
    return client
