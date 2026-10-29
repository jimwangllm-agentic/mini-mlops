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

The worker container starts with this command (shown for explanation; do not start another worker directly in Ubuntu):

```bash
celery -A app.tasks:celery worker --loglevel=info --concurrency=1
```

Show worker logs and the PostgreSQL row using the commands in [README: Inspect each part](../README.md#5-inspect-each-part). Read [app/db.py](../app/db.py) for the persisted job schema. Redis is the broker; PostgreSQL is the source of job status/results. A Celery result backend is unnecessary. Multiple workers pull from the same queue, each with concurrency 1. The UUID is also the Celery task ID, which helps correlate logs.

Read [app/tasks.py](../app/tasks.py). Completed-job redelivery is skipped. Concurrent duplicates can still compute twice; this is not exactly-once execution. Inference has no external side effect beyond storing the result.

### Check Celery and watch a submitted request in WSL

Open **Ubuntu WSL** and load this prepared laptop's tools and cluster configuration:

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh

# Check the worker container: expect READY 1/1 and STATUS Running.
kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker

# Ask Celery itself to respond through Redis: expect OK and pong.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/worker -- celery -A app.tasks:celery inspect ping --timeout=10
```

`Running` describes the Pod; `pong` confirms that a Celery worker responds through
the broker. To prove prediction works too, submit a request and read its result.

In the first WSL terminal, follow the worker logs:

```bash
# -f keeps watching new log lines. Ctrl+C ends this view, not the worker.
kubectl --context kind-mini-mlops -n mini-mlops logs deployment/worker --tail=20 -f
```

Now submit **POST /jobs** in [Swagger](http://localhost:8000/docs) and copy the UUID.
Use the suggested valid measurements `[5.1, 3.5, 1.4, 0.2]`: HTTP `202` means accepted;
HTTP `422` means invalid input and no task was queued. Four zeros are invalid.
Find that same ID in the terminal:

```text
Task predict[YOUR-JOB-ID] received
Task predict[YOUR-JOB-ID] succeeded in ...s: None
```

"received" shows Celery consumed the message; "succeeded" shows the task finished.
`None` is normal: this task writes the prediction to PostgreSQL instead of returning
a Celery result. Show the saved prediction with Swagger's **GET /jobs/{job_id}**.

In a second WSL terminal, run the same `source` command, then inspect current work:

```bash
# Lists tasks executing now; an empty reply (- empty -) means idle, which is normal.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/worker -- celery -A app.tasks:celery inspect active --timeout=10
```

Iris predictions finish quickly, so logs show completed requests more reliably than
an `inspect active` snapshot. Celery's result backend is disabled in this project;
PostgreSQL and GET `/jobs/{job_id}` provide the durable status/result.
For all worker replicas and a flag-by-flag explanation, see
[Beginner guide: Check Celery and watch a request](BEGINNER-GUIDE.md#check-celery-and-watch-a-request-in-wsl).

### Inspect Redis messages and PostgreSQL results in WSL

After loading `demo-env.sh` above, inspect the queue and the newest submitted job:

```bash
# Number of messages still waiting in this demo's default Celery queue.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli LLEN celery

# Newest message still waiting in Redis; empty/nil is normal once consumed.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli LINDEX celery 0

# Latest submitted job, with input, status, saved prediction, and any error.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/postgres -- \
  psql -U demo -d demo -x -c \
  "SELECT * FROM prediction_jobs ORDER BY created_at DESC LIMIT 1;"
```

`-U demo` selects the database user, `-d demo` selects the database, and `-x`
displays each field on its own line. `ORDER BY created_at DESC` puts the newest
submitted job first; `LIMIT 1` displays only that record. Change it to `LIMIT 3`
to see the latest three jobs. See the [local demo monitoring commands](LOCAL-DEMO.md#monitor-a-prediction-in-wsl)
for Celery logs, Redis queue writes, and the last three PostgreSQL records together.

Redis is a queue here, not completed-task history: after a task is consumed and
acknowledged, its message is removed. `LLEN` returning `0` does not mean that no
request arrived. PostgreSQL retains the result; `result` can still be empty while
the newest submitted job is queued/running. The query orders by submission time,
not completion time, because this small schema has no completion timestamp.

To watch new queue writes live, start this command **before** submitting in Swagger:

```bash
# MONITOR streams live Redis commands; grep shows writes to the celery queue.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli MONITOR | grep --line-buffered -i '"LPUSH" "celery"'
```

`LPUSH` means a task was enqueued. Celery's `received` log confirms consumption;
PostgreSQL shows the saved prediction. MONITOR is a live debugging view, not a
history query; use it briefly and stop with Ctrl+C. See the
[beginner explanation](BEGINNER-GUIDE.md#inspect-redis-and-postgresql-in-wsl) for flags and automatic refresh.

## 3. Model lifecycle — 1 minute

Open [MLflow](http://localhost:5000): `iris-demo` experiment, training parameters, held-out accuracy, logged model, registered `iris` version, `champion` alias. Show [app/train.py](../app/train.py). The train/test split is stratified with a fixed random seed; scaling and logistic regression are one sklearn Pipeline, fitted on training data only.

Retrain with `docker compose run --rm train` (Compose mode). Submit a new request and show a newer recorded model version. Workers resolve the alias on each job, caching the loaded model by immutable version. Discuss promotion after validation and moving the alias back for rollback. A model rollout strategy and rollback gates would need more work in production.

## 4. Packaging and orchestration — 2 minutes

### First understand the Kubernetes names

Kubernetes is the manager that keeps application containers running. Terraform
sends it the desired configuration through its API. The terms below describe
different things; a Deployment is not itself a running container.

| Term | Plain-English meaning | In this demo |
|---|---|---|
| Image | Packaged software used to start a container | `mini-mlops:local` contains Python, our code, and libraries |
| Container | A running instance of that packaged software | A process running Celery, FastAPI, Redis, etc. |
| Pod | The unit Kubernetes schedules onto a node; can contain one or more containers | Each service Pod here contains one container |
| Node | A machine/environment that runs Pods | kind uses the Docker container `mini-mlops-control-plane` as our one local node |
| Cluster | The complete Kubernetes system: its control plane and nodes | The local kind cluster named `mini-mlops` |
| Deployment | Defines a Pod template and desired replica count; manages ReplicaSets for updates | `worker` asks for one copy of the Celery worker by default |
| ReplicaSet | Maintains the requested number of matching Pods | The worker's ReplicaSet creates a replacement if its Pod disappears |
| Replica | One copy of a Pod, not a separate kind of running process | Two worker replicas means two worker Pods, each with one Celery container |
| Job | Runs finite work until successful completion | A training Job runs `python -m app.train`, registers the model, then finishes |
| Service | A stable internal network address routing to matching ready Pods | `api:8000` still works when the individual API Pod is replaced |
| Namespace | A named grouping of Kubernetes resources | `mini-mlops` groups this project's Deployments, Pods, Services, and storage |
| PersistentVolumeClaim / PVC | Requests storage that can outlive a Pod | PostgreSQL's claim lets a replacement Pod reuse saved prediction records |
| ConfigMap | Stores non-secret configuration files/settings | Prometheus scrape settings and Grafana's provisioned dashboard files |

The [plain-English comments in main.tf](../terraform/main.tf) translate each
resource into requests such as: "Hi Kubernetes, please maintain a worker
Deployment with one Pod, using this image and Celery command."

Show [Dockerfile](../Dockerfile): Python 3.12 and pinned direct dependencies in [requirements.txt](../requirements.txt). The same image has different commands for API, worker, training, and MLflow in [compose.yaml](../compose.yaml). This reduces demo setup, though production commonly splits image dependencies and runs non-root containers.

Read [terraform/main.tf](../terraform/main.tf) for Kubernetes resources and [scripts/deploy.sh](../scripts/deploy.sh) for deployment and training. Follow [README: Run Kubernetes + Terraform](../README.md#6-run-kubernetes--terraform) for setup and port-forwarding.

### Check Kubernetes status in WSL

If this is a new Ubuntu terminal, first load the prepared laptop's configuration.
For another machine, complete the README setup and select its kind context instead.

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh

# Confirm that Kubernetes' management API is reachable.
kubectl --context kind-mini-mlops cluster-info

# Confirm that the node says Ready.
kubectl --context kind-mini-mlops get nodes

# Check requested/ready replicas: each service should show READY 1/1 by default.
kubectl --context kind-mini-mlops -n mini-mlops get deployments

# Inspect individual Pods, service addresses, storage claims, and training Jobs.
kubectl --context kind-mini-mlops -n mini-mlops get pods,services,pvc,jobs
```

Service Pods should show `Running` and `1/1`. The training Pod showing `Completed`
and `0/1` is normal because its process exited successfully. `RESTARTS` is a historical
count, not automatically a current failure; a repeatedly increasing count needs investigation.
If the cluster is stopped after a reboot, use the [restart guide](LOCAL-DEMO.md#start-again-after-a-reboot).
See [the beginner status explanation](BEGINNER-GUIDE.md#check-kubernetes-status-in-wsl) for individual command parts.

### Show Deployments, ReplicaSets, and Pods

Use this command during the demo after loading `demo-env.sh` in your WSL terminal:

```bash
kubectl --context kind-mini-mlops -n mini-mlops get deployments,replicasets,pods
```

For a new terminal, the complete copy-and-paste sequence is:

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh
kubectl --context kind-mini-mlops -n mini-mlops get deployments,replicasets,pods
```

"The worker Deployment requests one running copy. Its ReplicaSet maintains that
number of Pods. The worker Pod contains the container that runs Celery. Terraform
sends the desired Deployment definition to Kubernetes' API; Kubernetes creates
these supporting objects and starts the container."

Use the `worker` names in the output to show the chain:

```text
Deployment: worker
    -> ReplicaSet: worker-<template-hash>
        -> Pod: worker-<template-hash>-<unique-suffix>
            -> Container: runs Celery
```

The actual hashes/suffixes vary. A Deployment's `READY 1/1` means one ready Pod out
of one desired. Older ReplicaSets with zero desired/current Pods can remain after
updates; they do not mean extra workers are running. The completed training Pod
is created by a Kubernetes Job, so it does not belong to this Deployment chain.
See [the beginner explanation](BEGINNER-GUIDE.md#show-deployments-replicasets-and-pods).

The node hosts the Pod/container; the Deployment and ReplicaSet are the objects
that manage how many Pods should exist. If a container crashes, Kubernetes can
restart it in the same Pod. If a managed Pod disappears, its ReplicaSet creates
a replacement Pod. Scaling the worker from one to two replicas keeps the same
Deployment and increases its ReplicaSet's desired Pod count to two.

Training follows a different ownership chain:

```text
Training Job: run the training program to completion
    -> Training Pod: assigned to the local node
        -> Container: runs python -m app.train, then exits
```

A prediction's UUID is an **application job**, stored in PostgreSQL and queued
through Redis. Submitting a prediction does not create a new Kubernetes Job or
Pod: an already-running Celery worker Pod processes that message. A GitHub Actions
job is another meaning of the word: a group of CI/CD steps on a runner.

Then show Terraform's infrastructure preview and manual worker scaling:

```bash
terraform -chdir=terraform plan
terraform -chdir=terraform apply -var='worker_replicas=2'
kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker
```

"kind bootstraps Kubernetes using Docker. Terraform reconciles resources inside the cluster: namespace, deployments, services, configuration, and storage claims. Kubernetes schedules pods and restarts failed processes. Scaling from 1 to 2 workers increases potential concurrent inference from 1 to 2. CPU, memory, and DB capacity still limit throughput."

This is manual scaling. There is no HPA, KEDA, production ingress, or cloud cluster provisioning. API readiness checks PostgreSQL; it does not prove Redis, model registry, and worker availability. Stateful services have a single replica and use a Recreate strategy. Do not claim high availability or zero-downtime releases.

### High concurrency: what to change, and who does what

Suppose many users submit predictions at the same time. There are two separate
stages to consider: **accepting HTTP requests** and **executing queued predictions**.
FastAPI returns HTTP 202 after saving/enqueueing a job; that does not mean the
prediction has finished. Redis buffers waiting messages while Celery processes them.

**Example: workers cannot finish jobs quickly enough.** Imagine a heavier model
takes one second per prediction and ten jobs arrive in a burst. With one worker
Pod and `--concurrency=1`, it executes roughly one job at a time, taking about ten
seconds to clear that burst. With three ready worker Pods, up to three jobs can
execute together: roughly four one-second waves for ten jobs. This is an illustrative
calculation, not an Iris benchmark; startup, model loading, CPU, and database work
also affect real completion times.

| Parameter or component | What changing it does | Where it is configured |
|---|---|---|
| `worker_replicas`: 1 -> 3 | Requests three Celery worker Pods consuming the same Redis queue | The variable and worker recipe in [main.tf](../terraform/main.tf) |
| Celery `--concurrency=1` -> `--concurrency=2` | Allows two task execution processes per worker Pod; uses more CPU/memory | The worker `command` in [main.tf](../terraform/main.tf) |
| API recipe `replicas = 1` -> `2` | Requests two API Pods for HTTP-serving capacity | The `api` entry in [main.tf](../terraform/main.tf); there is currently no `api_replicas` variable |
| CPU/memory `requests` and `limits` | Requests influence scheduling; limits cap each container's usage | The Deployment resource's `resources` block in [main.tf](../terraform/main.tf) |

Potential simultaneous predictions are approximately **worker Pods x Celery
concurrency per Pod**. Three Pods with concurrency 1 allow three task executions;
three Pods with concurrency 2 allow six. This is concurrency, not requests per
second, and it does not guarantee a proportional throughput improvement.

**Demonstrate manual worker scaling in WSL:**

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh

# Check how many messages are waiting. This excludes tasks already executing.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli LLEN celery

# Preview changing the desired worker count from one to three.
terraform -chdir=terraform plan -var='worker_replicas=3'

# Apply the change; review the plan and type yes at the prompt.
terraform -chdir=terraform apply -var='worker_replicas=3'

# Wait until all three requested worker Pods are ready, then display them.
kubectl --context kind-mini-mlops -n mini-mlops rollout status deployment/worker --timeout=180s
kubectl --context kind-mini-mlops -n mini-mlops get deployment worker
kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker

# Return to the small default after the demonstration; approve when prompted.
terraform -chdir=terraform apply -var='worker_replicas=1'
```

When you apply `worker_replicas=3`, these are the responsibilities:

1. **You choose three replicas.** Terraform does not monitor traffic or select this number automatically.
2. **Terraform sends an update to the Kubernetes API:** "Please make the worker Deployment maintain three Pods."
3. **Kubernetes updates the existing Deployment/ReplicaSet's desired count.** The ReplicaSet creates the extra Pods; the scheduler places them on the node, and the node starts their containers.
4. **The new Celery processes connect to Redis.** They independently consume messages from the same queue, allowing several predictions to run together. The worker does not need a Kubernetes HTTP Service.
5. **PostgreSQL receives their saved statuses/results.** Check queue depth, worker logs, completion times, and resource use to see whether the change helped.

Changing only the replica count uses the existing image and Pod template; it does
not rebuild the image or create three separate Deployments. The `-var` value applies
to that Terraform invocation and does not edit the variable's default in `main.tf`.
Use the same intended value in future applies, or maintain it in your variable settings.

**If the bottleneck is accepting HTTP requests instead:** change the API recipe's
replica count and apply. A Kubernetes Service can distribute connections across
matching ready API Pods; it does not run predictions or decide how many replicas
to create. Our localhost `kubectl port-forward service/api` tunnel selects one Pod,
so it is not a demonstration of production HTTP load balancing. A real ingress or
load-balancer path and per-Pod metrics discovery would be needed for that demonstration.

More worker Pods help only while CPU, memory, Redis, and PostgreSQL have capacity.
They still share this laptop's single node. Extra Pods can remain `Pending` if their
requests cannot fit; increasing replicas does not add physical laptop resources.
For continuous load, processing capacity must exceed the arrival rate to drain a
backlog: three one-second workers cannot keep up with ten jobs arriving every second.
Bounded queues, admission/rate limits, and retry policies are additional production
design choices, not features automatically added by Terraform.

**Automatic scaling is a separate feature.** A configured HorizontalPodAutoscaler
can adjust a Deployment's replica count from metrics; queue-based scaling can use
KEDA. Neither is installed/configured in this demo. Terraform would provision those
rules, and the autoscaler would react at runtime without a new Terraform apply for
every traffic spike. Manual Terraform applies must not repeatedly overwrite a
replica count owned by an autoscaler; that ownership needs deliberate configuration.

Interview wording: "I first identify whether HTTP handling or prediction execution
is the bottleneck. Here I can increase worker_replicas with Terraform. Kubernetes
creates more worker Pods, and Celery consumes more Redis jobs concurrently. I verify
that queue wait time improves rather than assuming more replicas solve every bottleneck."

References: [Kubernetes port forwarding](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
and [Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/).

### Why use Terraform if Kubernetes already has these commands?

**You do not need Terraform to run Kubernetes.** Kubernetes already supports
creating Deployments, changing replicas, and managing containers. This project
includes Terraform because it is one of the technologies we want to demonstrate.

These are two alternative ways to request three worker Pods. Run them from the
prepared WSL project environment described above:

| Method | Command | What happens |
|---|---|---|
| Kubernetes directly | `kubectl --context kind-mini-mlops -n mini-mlops scale deployment/worker --replicas=3` | Immediately updates the worker Deployment's desired replica count to three |
| Terraform | `terraform -chdir=terraform apply -var='worker_replicas=3'` | Reads the configuration, previews changes, and updates the worker Deployment through the Kubernetes API after approval |

**Kubernetes does the actual work in both cases:** creating the extra Pods,
starting their containers, and replacing failed Pods. Terraform does not run the
containers itself. It also does not need to run the `kubectl scale` command;
its Kubernetes provider talks to the Kubernetes API directly.

Terraform lets you **describe and manage the intended setup in files**.
Our [main.tf](../terraform/main.tf) describes Deployments, Services, storage,
and other resources together. Terraform compares that configuration with the
existing resources, previews the differences, and applies the requested changes.
The files can be reviewed and versioned in Git.

Here is why changing the same setting through both tools can be confusing:

1. The default in `main.tf` requests **one worker**.
2. You run `kubectl scale ... --replicas=3`. Kubernetes now maintains **three workers**.
3. You later run `terraform -chdir=terraform apply` with the default variable value.
   Terraform detects the difference and, after approval, requests **one worker again**.

Terraform does not continuously undo your manual changes in the background.
The change back happens when you apply configuration that requests one worker.
Keep the intended replica count consistent in your Terraform variable settings
when you want Terraform to manage it.

For this small demo, Kubernetes YAML configuration files plus `kubectl apply`
would also be sufficient. Terraform is an optional way to manage those resources.
In a larger cloud project, Terraform can also provision the network, Kubernetes
cluster, and managed databases. Our current Terraform configuration manages
resources **inside an existing kind cluster**; it does not provision cloud infrastructure.

Interview wording: "Kubernetes runs and maintains our containers. Terraform
defines and applies our intended infrastructure configuration. Terraform is
optional for Kubernetes, but helps manage that configuration consistently."

## 5. CI/CD and monitoring — 2 minutes

Show the [GitHub Actions workflow](../.github/workflows/ci.yml): test against PostgreSQL; Terraform fmt/validate; build an image identified by commit; deploy temporary kind; train; smoke test the real async path with [scripts/smoke.py](../scripts/smoke.py); cleanup. Read [tests/test_app.py](../tests/test_app.py) for the application tests and open [Actions runs](https://github.com/jimwangllm-agentic/mini-mlops/actions) for execution results. PRs test, while main pushes also deploy. The deployment lives on the hosted runner and is deleted afterwards; it does not update the laptop automatically.

The actual deployment commands in [scripts/deploy.sh](../scripts/deploy.sh) include:

```bash
docker build -t "$IMAGE" .
kind load docker-image "$IMAGE" --name mini-mlops
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -auto-approve -input=false
```

Every push to `main`, including docs-only commits, runs the workflow because there
is no path filter. Each deployment run creates a fresh temporary kind cluster and
local Terraform state on the GitHub runner; it rebuilds the image and provisions
the resources again. It trains/registers a model, runs `python scripts/smoke.py`,
then executes `kind delete cluster --name mini-mlops`. It does not update or erase
the laptop's cluster, models, or job database. Images stay on that runner; this
demo workflow does not publish them to a registry.

Open the [Grafana Iris dashboard](http://localhost:3000/d/iris-demo) (login `admin` / `admin`) and [Prometheus targets](http://localhost:9090/targets). Read [monitoring/dashboard.json](../monitoring/dashboard.json) for chart queries and [monitoring/prometheus.yml](../monitoring/prometheus.yml) for scrape configuration. Local UI links require the Compose stack or Kubernetes port-forwards to be running. Explain:

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
