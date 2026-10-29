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

Continue with [the runnable README](../README.md) and then the
[interview walkthrough](INTERVIEW.md). Start by demonstrating one prediction;
add infrastructure details only when you are comfortable explaining them.
