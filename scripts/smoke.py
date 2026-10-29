"""Standard-library-only, end-to-end check against a running deployment."""
import json
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"


def request(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(base + path, data=data, headers={"Content-Type": "application/json"}), timeout=10) as response:
        return response.status, json.load(response)


for attempt in range(90):
    try:
        request("/health")
        break
    except (URLError, TimeoutError):
        time.sleep(2)
else:
    raise SystemExit("API did not become healthy within 180 seconds")

status, submitted = request("/jobs", {"features": [5.1, 3.5, 1.4, 0.2]})
assert status == 202, submitted
for attempt in range(60):
    _, job = request("/jobs/" + submitted["id"])
    if job["status"] == "failed":
        raise SystemExit(f"Prediction failed: {job}")
    if job["status"] == "succeeded":
        assert job["result"]["class_name"] == "setosa", job
        assert job["result"]["model_version"], job
        print(json.dumps(job, indent=2))
        break
    time.sleep(1)
else:
    raise SystemExit("Prediction did not finish within 60 seconds")

try:
    request("/jobs", {"features": [1, 2]})
    raise AssertionError("Invalid input was accepted")
except HTTPError as error:
    assert error.code == 422, error

with urlopen(base + "/metrics", timeout=10) as response:
    assert b'prediction_jobs{status="succeeded"}' in response.read()
print("PASS: API -> PostgreSQL -> Redis -> Celery -> MLflow model -> result + metrics")
