# A 10-minute interview walkthrough

New to Docker, YAML, or Kubernetes? Start with the [beginner's guide](BEGINNER-GUIDE.md).
The [Compose configuration](../compose.yaml), [CI workflow](../.github/workflows/ci.yml),
[Dockerfile](../Dockerfile), and [deployment script](../scripts/deploy.sh) include comments explaining their settings and commands.

Opening: "I built an asynchronous model-serving application. FastAPI validates requests; Redis buffers jobs; Celery workers run a versioned MLflow model; PostgreSQL persists results. Docker packages it. Terraform provisions the local Kubernetes resources. GitHub Actions tests and deploys the same stack to a temporary cluster. Prometheus and Grafana show operational metrics."

## 1. Request and validation — 1 minute

Open [Swagger UI](http://localhost:8000/docs) and submit `{"features":[5.1,3.5,1.4,0.2]}`. Show HTTP 202 with a UUID, then poll GET `/jobs/{id}`. Submit only two values to show 422. Explain that 202 means accepted for processing, not inference complete.

Read [app/main.py](../app/main.py): validation, persistence before enqueue, and status lookup. The request thread does not perform inference. A bounded range rejects NaN/infinity and nonsensical measurements, but it is not drift detection or a guarantee of model validity.

## 2. Worker and storage — 2 minutes

"A worker is a background Python process. For this request it takes the UUID from Redis, reads four measurements from PostgreSQL, marks the row running, loads the champion model version from MLflow, predicts setosa, and saves the result/version as succeeded."

The worker starts with:

```bash
celery -A app.tasks:celery worker --loglevel=info --concurrency=1
```

Show worker logs and the PostgreSQL row using the commands in [README: Inspect each part](../README.md#5-inspect-each-part). Read [app/db.py](../app/db.py) for the persisted job schema. Redis is the broker; PostgreSQL is the source of job status/results. A Celery result backend is unnecessary. Multiple workers pull from the same queue, each with concurrency 1. The UUID is also the Celery task ID, which helps correlate logs.

Read [app/tasks.py](../app/tasks.py). Completed-job redelivery is skipped. Concurrent duplicates can still compute twice; this is not exactly-once execution. Inference has no external side effect beyond storing the result.

## 3. Model lifecycle — 1 minute

Open [MLflow](http://localhost:5000): `iris-demo` experiment, training parameters, held-out accuracy, logged model, registered `iris` version, `champion` alias. Show [app/train.py](../app/train.py). The train/test split is stratified with a fixed random seed; scaling and logistic regression are one sklearn Pipeline, fitted on training data only.

Retrain with `docker compose run --rm train` (Compose mode). Submit a new request and show a newer recorded model version. Workers resolve the alias on each job, caching the loaded model by immutable version. Discuss promotion after validation and moving the alias back for rollback. A model rollout strategy and rollback gates would need more work in production.

## 4. Packaging and orchestration — 2 minutes

Show [Dockerfile](../Dockerfile): Python 3.12 and pinned direct dependencies in [requirements.txt](../requirements.txt). The same image has different commands for API, worker, training, and MLflow in [compose.yaml](../compose.yaml). This reduces demo setup, though production commonly splits image dependencies and runs non-root containers.

Read [terraform/main.tf](../terraform/main.tf) for Kubernetes resources and [scripts/deploy.sh](../scripts/deploy.sh) for deployment and training. Follow [README: Run Kubernetes + Terraform](../README.md#6-run-kubernetes--terraform) for setup and port-forwarding. In Kubernetes mode show:

```bash
kubectl --context kind-mini-mlops -n mini-mlops get pods,services,pvc,jobs
terraform -chdir=terraform plan
terraform -chdir=terraform apply -var='worker_replicas=2'
kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker
```

"kind bootstraps Kubernetes using Docker. Terraform reconciles resources inside the cluster: namespace, deployments, services, configuration, and storage claims. Kubernetes schedules pods and restarts failed processes. Scaling from 1 to 2 workers increases potential concurrent inference from 1 to 2. CPU, memory, and DB capacity still limit throughput."

This is manual scaling. There is no HPA, KEDA, production ingress, or cloud cluster provisioning. API readiness checks PostgreSQL; it does not prove Redis, model registry, and worker availability. Stateful services have a single replica and use a Recreate strategy. Do not claim high availability or zero-downtime releases.

## 5. CI/CD and monitoring — 2 minutes

Show the [GitHub Actions workflow](../.github/workflows/ci.yml): test against PostgreSQL; Terraform fmt/validate; build an image identified by commit; deploy temporary kind; train; smoke test the real async path with [scripts/smoke.py](../scripts/smoke.py); cleanup. Read [tests/test_app.py](../tests/test_app.py) for the application tests and open [Actions runs](https://github.com/jimwangllm-agentic/mini-mlops/actions) for execution results. PRs test, while main pushes also deploy. The deployment lives on the hosted runner and is deleted afterwards; it does not update the laptop automatically.

Open the [Grafana Iris dashboard](http://localhost:3000/d/iris-demo) (login `admin` / `demo-admin`) and [Prometheus targets](http://localhost:9090/targets). Read [monitoring/dashboard.json](../monitoring/dashboard.json) for chart queries and [monitoring/prometheus.yml](../monitoring/prometheus.yml) for scrape configuration. Local UI links require the Compose stack or Kubernetes port-forwards to be running. Explain:

- `up`: can Prometheus scrape the API?
- Request rate: how much traffic reaches API routes?
- Latency histogram: API response latency, not end-to-end asynchronous completion time.
- Job status gauge: current durable counts from PostgreSQL, not process-local counters. Completed jobs remain counted after API restarts.

The demo scrapes a single API Service target; this is enough for one API replica. For multiple replicas, configure pod endpoint discovery and aggregate per-pod metrics appropriately. Add oldest queued job age, end-to-end job duration, worker failures, and resource saturation next.

## 6. Honest limitations — 2 minutes

"This demonstrates integration, not production readiness. For a shared environment I would add authentication, TLS, secret management, schema migrations, managed/high-availability storage, and upgrade/review these pinned demo dependencies. I would benchmark before choosing replicas."

Reliability questions:

| Question | Answer |
|---|---|
| Why async for a tiny Iris model? | For teaching the queue architecture. For such cheap inference, synchronous serving is usually simpler. Async becomes useful for slow/bursty jobs. |
| What if API crashes after DB commit but before publish? | A queued row may have no message. A transactional outbox with a dispatcher closes this gap. |
| What if a worker crashes mid-job? | Late acknowledgement permits redelivery; a running row can be processed again. Exactly-once is not guaranteed. |
| What if Redis loses messages? | AOF helps local persistence, but it is not HA. Production needs explicit durability/recovery design. |
| What if model loading fails? | The worker records failed, logs an exception, and the client sees a safe error category. Fix the dependency and submit another job. |
| Why no automatic retries? | To keep failure behavior small and explicit. Production retries transient failures with backoff/jitter and sends poison jobs to dead-letter handling. |
| How many workers for 100 jobs/sec? | Benchmark service time. At 0.1 seconds/job, 10 concurrent workers is only the idealized minimum; add headroom and account for bottlenecks. |
| Why not Kafka? | This is task distribution. Kafka is useful when replayable event streams and independent consumer groups are requirements. |
| Why MLflow SQLite? | One local MLflow replica keeps the demo smaller. Application jobs still use PostgreSQL. For shared MLflow, move metadata to a managed DB and artifacts to object storage. |

Cloud equivalents and queue terminology are in [CLOUD-ALTERNATIVES.md](CLOUD-ALTERNATIVES.md).
