# Read this first: running the demo without prior Kubernetes knowledge

You do not need to memorize every command. Start with the request flow, then learn
what each configuration file starts and why.

## 1. The complete request in plain English

1. Your browser sends four flower measurements to FastAPI.
2. FastAPI creates a UUID and saves the input/status in PostgreSQL.
3. FastAPI also publishes that UUID to Redis using Celery's `apply_async()`.
4. A running Celery worker receives the Redis message and calls your `predict()` function.
5. The function reads the measurements from PostgreSQL and loads MLflow's champion model.
6. `model.predict([features])` calculates the species. The worker saves the result.
7. You ask FastAPI for the same UUID; it reads and returns the stored result.

The worker listens to Redis. It does not periodically scan PostgreSQL for new jobs.
Creating a database row alone does not schedule work; the queue publication is essential.

| Actual code | What to look for |
|---|---|
| [app/main.py](../app/main.py) | `PredictionInput`, `submit()`, `get_job()` |
| [app/tasks.py](../app/tasks.py) | `predict()` and the line `model.predict([features])` |
| [app/db.py](../app/db.py) | `Job` defines the stored row; `Session()` opens DB sessions |
| [app/train.py](../app/train.py) | `main()` trains/evaluates/registers the model before serving |

## 2. Three different kinds of files

| File type | Meaning | Example |
|---|---|---|
| Python, `.py` | Executable application logic | The prediction function |
| YAML, `.yaml` / `.yml` | Settings read by a tool | Compose or GitHub Actions configuration |
| Shell, `.sh` | Commands executed in sequence by Bash | Build and deployment script |
| Terraform, `.tf` | Desired infrastructure resources | Kubernetes Deployments and storage |

YAML indentation creates parent/child relationships. A `-` begins a list item.
Text after `#` is a comment for you; the tool ignores it. A YAML key can be a
setting rather than a shell command: `image:` tells Compose which image to run;
`command:` supplies the command to run inside that container.

## 3. Image versus container

An **image** is a packaged application environment, like a reusable template.
A **container** is a running instance of that image. Many containers can start
from one image with different commands.

Our [Dockerfile](../Dockerfile) creates one image containing Python and our app.
The API runs Uvicorn, the worker runs Celery, training runs `python -m app.train`,
and MLflow runs `mlflow server`. Those commands select different processes from
the same packaged environment.

| Command | Plain-English meaning |
|---|---|
| `docker build -t mini-mlops:local .` | Build the current folder's Dockerfile; name/tag its image |
| `docker compose up --build -d` | Build required images, then start this project's containers in the background |
| `docker compose ps -a` | List this project's running and exited containers |
| `docker compose logs worker` | Read the Celery worker container's output |
| `docker compose exec postgres ...` | Execute a command inside the running PostgreSQL container |
| `docker compose down` | Remove this project's containers/network while retaining named data volumes |

Do not use `down -v` before an interview unless you intend to erase the demo's
saved database, Redis data, and model registry/artifacts.

## 4. Read compose.yaml as a list of services

Open [compose.yaml](../compose.yaml). It now explains its settings beside the code.

- `services` lists the containers: database, queue, MLflow, trainer, API, worker, monitoring.
- `image` selects a packaged environment; `build` says how to create it.
- `environment` supplies configuration such as database and model server URLs.
- `depends_on` controls startup prerequisites. A running container can still be unready.
- `healthcheck` asks a running service to prove it is ready to answer requests.
- `ports` makes a container port reachable from your laptop.
- `volumes` connects persistent storage or a local configuration file to a container path.

In `127.0.0.1:8000:8000`, the first part is the laptop's loopback address, the
middle is the laptop port, and the last is the API container's port. Your browser
opens `http://localhost:8000`. Inside containers, `postgres`, `redis`, and `mlflow`
are service hostnames; `localhost` would refer to that individual container.

`&app` names a reusable YAML block. `*app` refers to it. `<<: *app` merges its
settings into the service. This avoids repeating the same image/configuration.

## 5. Kubernetes: the same services under a different manager

Compose manages this application's containers directly. Kubernetes manages
application workloads through resources such as Pods and Deployments. The
Python prediction code stays the same.

| Term | What it means here |
|---|---|
| Cluster | The whole local Kubernetes environment |
| Node | A machine that runs Kubernetes workloads; kind simulates one using a Docker container |
| Control plane | Kubernetes' management processes: accept resource definitions and coordinate work |
| Namespace | A grouping named `mini-mlops` that keeps this demo's resources together |
| Pod | The unit Kubernetes runs; in this demo each app Pod contains one service container |
| Deployment | Requests a number of Pods and replaces them when they exit/fail |
| ReplicaSet | Maintains a requested number of matching Pods; a Deployment manages it |
| Replica | One copy of a Pod; two worker replicas can process two tasks concurrently here |
| Service | Stable internal network address that routes to matching ready Pods |
| Label | A resource tag such as `app=worker`, used for selection and routing |
| PVC | PersistentVolumeClaim: asks Kubernetes for storage surviving Pod replacement |
| ConfigMap | Stores non-secret configuration, such as Prometheus's scrape settings |
| Job | A run-to-completion Kubernetes workload; our model training is one |
| Context | A kubectl connection/profile selecting a cluster and credentials |

Three uses of the word **job** are different: a prediction job is an application
database row; a Kubernetes Job runs training; a GitHub Actions job groups CI steps.

Our [terraform/main.tf](../terraform/main.tf) creates the Kubernetes resources
directly through a provider. That is why this project does not have another large
set of Kubernetes YAML files. [scripts/deploy.sh](../scripts/deploy.sh) runs the setup.

## 6. Decode a kubectl command

```bash
kubectl --context kind-mini-mlops -n mini-mlops get pods
```

| Part | Meaning |
|---|---|
| `kubectl` | Command-line client talking to Kubernetes |
| `--context kind-mini-mlops` | Choose this demo's cluster connection |
| `-n mini-mlops` | Look inside this demo's namespace |
| `get` | List resources |
| `pods` | The resource type to list |

Other endings you will see after that same prefix:

| Ending | What it does |
|---|---|
| `get services,pvc,jobs` | List internal network addresses, storage requests, and training Jobs |
| `logs deployment/worker` | Print logs from a worker Pod managed by that Deployment |
| `get pods -l app=worker` | List only Pods carrying the worker label |
| `rollout status deployment/api --timeout=300s` | Wait up to five minutes for the API's requested Pods to be ready |
| `port-forward service/api 8000:8000` | Open a temporary tunnel from your local port to the API Service |

Port forwarding runs continuously. In the README's manual setup, leave that
terminal open. The laptop-specific `demo.sh` helper can run these tunnels in the background.

### Check Kubernetes status in WSL

On your prepared laptop, open **Ubuntu WSL** and run:

```bash
# Load the compatible kubectl, kubeconfig, and project directory for this laptop.
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh

# Is Kubernetes' management API reachable?
kubectl --context kind-mini-mlops cluster-info

# Is its node ready to run workloads?
kubectl --context kind-mini-mlops get nodes

# Are the requested copies of each service available?
kubectl --context kind-mini-mlops -n mini-mlops get deployments

# What is each individual Pod doing?
kubectl --context kind-mini-mlops -n mini-mlops get pods
```

`source` applies the settings from [demo-env.sh](../demo-env.sh) to your current
terminal. It also changes into the repository folder. Run it again in each new
terminal. It does not start the services. If they are stopped, follow
[Start again after a reboot](LOCAL-DEMO.md#start-again-after-a-reboot).
The absolute path above is specific to your prepared laptop; fresh installations
should follow the [README setup](../README.md) and their own kubeconfig/tool paths.

| Output | How to read it |
|---|---|
| `cluster-info` prints the control-plane address | Kubernetes answered the command; an address alone does not prove every app works |
| Node `STATUS Ready` | The node is ready to run workloads |
| Deployment `READY 1/1` | One ready Pod out of one desired; a scaled worker may show `2/2` |
| Service Pod `STATUS Running`, `READY 1/1` | Its container is running and considered ready; use application checks too |
| Training Pod `Completed`, `READY 0/1` | Normal: the one-off training process finished and is no longer running |
| `RESTARTS` | Previous restarts, including startup/reboot history; watch whether the count keeps increasing |
| `CrashLoopBackOff` | A container keeps exiting and Kubernetes is delaying its next retry; inspect its logs |
| `Pending` | The Pod has not been scheduled or its prerequisites are not ready yet |

`--context kind-mini-mlops` selects our cluster. `-n mini-mlops` selects this
project's namespace. Nodes belong to the whole cluster, so `get nodes` needs no `-n`.
The API and MLflow have HTTP readiness checks; the worker's Pod readiness alone
does not prove Celery is receiving tasks. Check Celery itself below.

If a Pod fails, inspect its logs and recent Kubernetes events:

```bash
# Replace deployment/api with deployment/worker to check the worker's logs.
kubectl --context kind-mini-mlops -n mini-mlops logs deployment/api --tail=50
kubectl --context kind-mini-mlops -n mini-mlops get events --sort-by=.lastTimestamp
```

### Show Deployments, ReplicaSets, and Pods

This is the command to show the Kubernetes workload chain during your demo.
Run it in Ubuntu WSL, loading the demo environment first in each new terminal:

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh
kubectl --context kind-mini-mlops -n mini-mlops get deployments,replicasets,pods
```

The comma-separated list asks Kubernetes to show three resource types in one
command. This reads their status; it does not create, restart, or change anything.

| Object | What it does | Worker example |
|---|---|---|
| Deployment | Defines the image, startup command, and desired number of Pods; manages updates | `worker` requests one worker Pod by default |
| ReplicaSet | Maintains the requested number of matching Pods | `worker-<template-hash>` maintains that copy |
| Pod | The unit scheduled onto a node; contains one container in this demo | `worker-<template-hash>-<unique-suffix>` contains the Celery container |
| Container | Runs the actual application process from an image | Executes `celery -A app.tasks:celery worker ...` |

The Deployment controller creates a ReplicaSet, and the ReplicaSet controller
creates Pods. The scheduler assigns each Pod to a node. The node's kubelet asks
its container runtime to start the containers. These Kubernetes programs are
already running in the kind cluster; you do not manually run their internal steps.

```text
Terraform submits a Deployment definition to the Kubernetes API
    -> Deployment controller creates a ReplicaSet
        -> ReplicaSet controller creates a Pod
            -> Scheduler selects a node
                -> Kubelet/container runtime starts the Celery container
```

In your output, find the rows whose names begin with `worker`. The sample names
above are placeholders; your real names contain generated hashes and suffixes.
`READY 1/1` on the Deployment means one ready Pod out of one desired. A ReplicaSet
shows desired/current/ready counts. Older ReplicaSets can remain with all counts
at zero after a deployment update; count the active Pods to see running workers.
The training Pod is different: a one-off Job owns it, and `Completed` is expected.

The [Deployment resource in main.tf](../terraform/main.tf) describes these workloads.
The [deployment script](../scripts/deploy.sh) creates the kind cluster first, then
invokes Terraform. Terraform sends API requests; it does not run a separate
`kubectl` command for each Deployment.

### Check Celery and watch a request in WSL

For the objects that manage the worker, see
[Show Deployments, ReplicaSets, and Pods](#show-deployments-replicasets-and-pods).

Celery is running **inside the worker Pod**, not directly in your Ubuntu shell.
Use `kubectl exec` to run Celery's inspection command inside that container, where
the application code, Python dependencies, and Redis configuration already exist.

First run the `source` command above in your WSL terminal, then:

```bash
# Find the worker Pod: expect Running with READY 1/1.
kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker

# Ask responding Celery workers to send a reply through Redis.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/worker -- celery -A app.tasks:celery inspect ping --timeout=10
```

Expected reply, with your actual worker Pod name:

```text
-> celery@worker-EXAMPLE: OK
        pong
```

| Part of the inspection command | Meaning |
|---|---|
| `exec deployment/worker` | Execute a command inside a Pod selected from the worker Deployment |
| `--` | End kubectl's arguments; the remaining words form the command inside the container |
| `celery` | Run Celery's command-line tool inside that container |
| `-A app.tasks:celery` | Load the Celery app object named `celery` from [app/tasks.py](../app/tasks.py), including its Redis connection settings |
| `inspect ping` | Ask workers to prove they respond to control messages |
| `--timeout=10` | Allow up to ten seconds to collect worker replies |

A `pong` confirms worker/broker responsiveness, not a successful ML prediction.
The next exercise checks that a submitted request actually reaches the task code.

**Terminal 1: watch the worker.**

```bash
# Show the last 20 lines, then keep printing new lines with -f (follow).
kubectl --context kind-mini-mlops -n mini-mlops logs deployment/worker --tail=20 -f
```

In [Swagger](http://localhost:8000/docs), submit **POST /jobs** with:

```json
{"features": [5.1, 3.5, 1.4, 0.2]}
```

Check the POST response first: **202** means the job was accepted and includes an
ID. **422** means input validation failed, so Celery receives no message. Use the
valid example above; four zeros are rejected because measurements must be positive.

Copy the returned job ID and look for the same ID in the terminal:

```text
Task predict[YOUR-JOB-ID] received
Task predict[YOUR-JOB-ID] succeeded in ...s: None
```

- `received`: Celery consumed the task message from Redis.
- `succeeded`: your Python task finished without raising an error.
- `None`: this task returns no value to Celery; it saves the prediction in PostgreSQL.
- The UUID connects the FastAPI response, Celery logs, and PostgreSQL job row.

Press **Ctrl+C** to stop following logs. This ends your log-viewing command and
does not stop the worker or the application. After scaling to multiple workers,
watch all current worker Pods with this label selector instead:

```bash
# -l selects worker Pods; --prefix=true includes the Pod/container on each line.
kubectl --context kind-mini-mlops -n mini-mlops logs -l app=worker --prefix=true --tail=20 -f
```

Restart the log command after scaling so it selects the new set of worker Pods.

**Terminal 2: ask Celery what it is doing right now.** Load `demo-env.sh` in this
new terminal, then run:

```bash
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/worker -- celery -A app.tasks:celery inspect active --timeout=10
```

The CLI displays `- empty -` when no task was executing when the worker answered
(an empty list `[]` in structured output). Iris predictions finish
quickly, so an empty list after submission is often normal: use logs to see work
that already finished. `inspect active` is a current snapshot, not a task history.

For the durable status/result, open **GET /jobs/{job_id}** in Swagger. This project
disables Celery's result backend and stores application results in PostgreSQL, so
Celery's result lookup is not the way to retrieve completed predictions here.

For a complete prediction check from WSL without the browser:

```bash
# Run from the repository folder selected by demo-env.sh.
bash demo.sh smoke
```

### Inspect Redis and PostgreSQL in WSL

Run the `source .../demo-env.sh` command above in each new WSL terminal first.
Redis contains waiting task messages; PostgreSQL contains the durable input,
status, and result. They answer different questions.

**Redis: how much work is waiting?**

```bash
# LLEN means list length; celery is this demo's default queue name.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli LLEN celery

# LINDEX reads one list item; 0 selects the newest queued message in this setup.
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli LINDEX celery 0
```

Celery writes new messages to the front of the Redis list and consumes from the
other end. A fast worker can consume a message before you inspect the list.
`LLEN` can therefore return `0`, and `LINDEX` can return nothing/nil, even after a
successful prediction. The message may also be executing already. Redis does not
keep completed task messages as a history table in this project.

**Redis: watch a new message get enqueued.** Start this before clicking Execute in Swagger:

```bash
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/redis -- redis-cli MONITOR | grep --line-buffered -i '"LPUSH" "celery"'
```

| Part | Meaning |
|---|---|
| `exec deployment/redis -- redis-cli` | Run Redis's CLI inside its container |
| `MONITOR` | Stream Redis commands as they happen, not past commands |
| `\|` | Pass that output to the next program in your WSL shell |
| `grep --line-buffered` | Print matching lines immediately rather than buffering them |
| `-i '"LPUSH" "celery"'` | Match writes to the demo queue, regardless of letter case |

The output includes the queued task's message envelope, whose headers contain the
job UUID. Its body is encoded, so do not expect the prediction result or readable
measurements there. `LPUSH` confirms enqueueing, not worker completion. Watch
Celery's `received`/`succeeded` logs and query PostgreSQL for those later stages.
MONITOR streams all Redis commands before filtering; use this live debugging view
briefly and stop with **Ctrl+C**. It does not stop Redis or Celery.

**PostgreSQL: show the newest submitted job and its prediction.**

```bash
kubectl --context kind-mini-mlops -n mini-mlops exec deployment/postgres -- psql -U demo -d demo -x -c "SELECT id, status, features, result, error, created_at FROM prediction_jobs ORDER BY created_at DESC LIMIT 1;"
```

| Part | Meaning |
|---|---|
| `psql` | PostgreSQL's command-line client, running inside the database container |
| `-U demo` | Connect as the database user named demo |
| `-d demo` | Connect to the demo database |
| `-x` | Show each field on its own line, making JSON results easier to read |
| `-c "..."` | Execute the quoted SQL query |
| `SELECT ... FROM prediction_jobs` | Read the chosen fields from the job table |
| `ORDER BY created_at DESC` | Sort newest submissions first |
| `LIMIT 1` | Return only the first row |

For a completed prediction, expect `status = succeeded` and a `result` containing
the species and model version. For queued/running jobs, `result` may still be empty.
This query finds the latest submission; it does not sort by completion time.
Change `LIMIT 1` to `LIMIT 5` to see recent submissions.

To refresh that query every two seconds, use Ubuntu's `watch` command:

```bash
watch -n 2 -x kubectl --context kind-mini-mlops -n mini-mlops exec deployment/postgres -- psql -U demo -d demo -x -c "SELECT id, status, result, error, created_at FROM prediction_jobs ORDER BY created_at DESC LIMIT 1;"
```

The first `-n 2` sets the watch interval. Watch's first `-x` preserves command
arguments, including the SQL string; psql's later `-x` formats the row vertically.
Press Ctrl+C to stop refreshing. This reads data; it does not update the job.

## 7. Terraform: describe resources, then create them

| Command | Meaning |
|---|---|
| `terraform -chdir=terraform init` | Prepare the folder and download provider plugins |
| `terraform -chdir=terraform validate` | Check configuration syntax and schemas |
| `terraform -chdir=terraform plan` | Preview how actual resources differ from the desired configuration |
| `terraform -chdir=terraform apply` | Make the resources match the desired configuration |
| `terraform -chdir=terraform apply -var='worker_replicas=2'` | Change the desired worker count to two and apply it |

`resource` declares something Terraform manages. `variable` is a configurable
input. `locals` names values computed/reused in the file. `for_each` creates one
resource for each map/list entry. `metadata` includes name/namespace/labels;
`spec` describes what Kubernetes should run. `template` describes a Deployment's Pods.

Terraform state records which resources belong to this configuration. It is
local/ignored in Git for this demo. Do not delete it before normal resource cleanup.

### How Terraform sends resources to Kubernetes

Think of Terraform's Kubernetes provider as an HTTP API client, similar to how
your browser is a client of FastAPI. `terraform apply` parses the `.tf` files and
the provider translates resource settings into requests to the Kubernetes API.

In [main.tf](../terraform/main.tf), this selects the cluster connection:

```hcl
provider "kubernetes" {
  config_path    = pathexpand(var.kube_config)
  config_context = var.kube_context
}
```

The kubeconfig contains the API server address and authentication/TLS settings.
On this prepared laptop, `demo-env.sh` sets `TF_VAR_kube_config` so Terraform uses
the workspace's kubeconfig, and the context is `kind-mini-mlops`.

For example, creating the worker Deployment uses Kubernetes' deployment API,
conceptually a request to:

```http
POST /apis/apps/v1/namespaces/mini-mlops/deployments
```

The request describes the name `worker`, replica count, image, container command,
and other resource settings. Kubernetes receives resource objects derived from
the configuration, not the original Terraform file. On an update, the provider
uses the appropriate update/patch requests instead of creating everything again.
The API server records the desired state; Kubernetes' controllers and node
components then create the ReplicaSet/Pods and run the containers.

The kind cluster must already exist. `init` installs/prepares the provider;
`apply` uses it to make API calls. It does not build Docker images or execute
`kubectl` internally. Our separate shell script builds/loads the image and invokes
Terraform, then uses `kubectl rollout status` to wait for ready Pods.

Official references: [Kubernetes API](https://kubernetes.io/docs/concepts/overview/kubernetes-api/)
and [Terraform Kubernetes provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/index).

## 8. GitHub Actions: testing on a separate machine

Open [.github/workflows/ci.yml](../.github/workflows/ci.yml). Its comments explain
each section and command. The test job checks code and Terraform; the deploy job
starts a temporary kind cluster on the GitHub runner and tests a real prediction.

| YAML key | Meaning |
|---|---|
| `on` | Events that start a workflow |
| `jobs` | Groups of work, normally on separate runner machines |
| `runs-on` | Which runner environment GitHub should provide |
| `steps` | Actions/commands executed in order within a job |
| `uses` | Invoke a reusable action provided by a repository/version |
| `with` | Inputs to that reusable action |
| `run` | Execute shell commands on the runner |
| `needs` | Wait for another job to succeed first |
| `if` | Condition deciding whether a job/step runs |
| `${{ github.sha }}` | The commit ID, substituted by GitHub before executing the command |

The runner is discarded afterward. A green workflow proves the tested deployment
worked there; your laptop's demo is a separate deployment with its own data.

### Does every commit rebuild and redeploy?

In this project, **every push to main** runs the workflow, even a documentation-only
change. The [workflow file](../.github/workflows/ci.yml) has no path filter:

```yaml
on:
  push:
    branches: [main]
```

The deploy job waits for tests with `needs: test`, then executes:

```yaml
run: IMAGE=mini-mlops:${{ github.sha }} bash scripts/deploy.sh
```

`github.sha` is the commit ID. GitHub substitutes it into the image tag so the
image identifies the exact source revision. The [deployment script](../scripts/deploy.sh)
runs these commands on the GitHub runner:

```bash
# Create a new local Kubernetes cluster on the runner if absent.
kind create cluster --name mini-mlops --image kindest/node:v1.32.2 --wait 120s

# Build the Python application image and put it into that cluster's runtime.
docker build -t "$IMAGE" .
kind load docker-image "$IMAGE" --name mini-mlops

# Prepare Terraform and create the Kubernetes resources.
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -auto-approve -input=false
```

It then trains/registers a model using a Kubernetes Job. The workflow checks a
real prediction with `python scripts/smoke.py` and removes the temporary cluster
with `kind delete cluster --name mini-mlops`.

Each deployment run uses a fresh runner, cluster, and local Terraform state, so
the resources are created again. This is not a persistent production CD target.
It neither updates nor deletes the laptop deployment. The image is not pushed
to a registry; it is used on the runner and disappears with that environment.

Continue with [the runnable README](../README.md) and then the
[interview walkthrough](INTERVIEW.md). Start by demonstrating one prediction;
add infrastructure details only when you are comfortable explaining them.
