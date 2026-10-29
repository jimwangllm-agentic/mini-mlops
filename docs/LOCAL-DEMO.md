# Your laptop demo

Project: [mini-mlops](../README.md). Source is also pushed to
[your private GitHub repository](https://github.com/jimwangllm-agentic/mini-mlops).

The setup uses Docker Desktop's Linux engine and your `Ubuntu-26.04` WSL distribution.
The application can run under Compose or Kubernetes. Their databases/models are separate.
Run one stack at a time to conserve laptop memory; the helper switches between them.

At handoff, Kubernetes was running, Compose was built and stopped, and Iris model
version 1 was registered. After a reboot, run the startup steps below to restore the local URLs.
Both Compose and Kubernetes prediction flows were verified from Windows. Grafana's
dashboard/datasource and Prometheus scraping were also checked. Worker scaling to two
Pods and back to one was verified; one worker is left running to keep the demo small.

## Open the demo

| Page | Address | What to demonstrate |
|---|---|---|
| FastAPI / Swagger | [localhost:8000/docs](http://localhost:8000/docs) | POST a prediction, copy the returned ID, GET its result |
| MLflow | [localhost:5000](http://localhost:5000) | Experiment `iris-demo`, accuracy, registered model `iris`, alias `champion` |
| Grafana | [Iris dashboard](http://localhost:3000/d/iris-demo) | Login `admin` / `admin`; request rate, latency, saved job counts |
| Prometheus | [Targets](http://localhost:9090/targets) | The API scrape target is UP |

Example input for **POST /jobs**:

```json
{"features": [5.1, 3.5, 1.4, 0.2]}
```

Expected result after polling **GET /jobs/{job_id}**: `succeeded`, species `setosa`,
and a recorded model version. The API returns the ID before the background worker finishes.

## Start again after a reboot

These steps are for your already-prepared laptop at the paths below. For a fresh
clone on another computer, follow [README setup](../README.md#1-install-windows-prerequisites)
first. The kubeconfig, downloaded tools, Terraform state, and database/model data
are local runtime files; they are intentionally not committed to GitHub.

Start Docker Desktop and wait until its engine is running. Then open **PowerShell**:

```powershell
cd C:\Users\pcc20\Documents\Codex\2026-10-28\can-x20\outputs\mini-mlops
.\demo.ps1 start
.\demo.ps1 smoke
```

If your PowerShell policy does not permit local scripts, run these in **Ubuntu WSL** instead:

```bash
cd /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops
bash demo.sh start
bash demo.sh smoke
```

`start` waits for Docker Desktop's WSL connection, stops this project's Compose containers, starts the existing local Kubernetes
node, waits for the application, and opens background port-forward tunnels. It retains data.
`smoke` sends a real prediction and checks the result plus validation/metrics.

## Small commands for the interview

From the same PowerShell folder:

```powershell
.\demo.ps1 status   # List the local node, Pods, Services, storage, and training Jobs.
.\demo.ps1 infra    # Terraform previews differences from the saved desired configuration.
.\demo.ps1 scale 2  # Run two Celery worker Pods instead of one.
.\demo.ps1 scale 1  # Return to one worker.
.\demo.ps1 smoke    # Submit and verify another real prediction.
.\demo.ps1 stop     # Stop the Kubernetes node while preserving demo data.
.\demo.ps1 compose  # Switch to the simpler Compose stack using the built image.
.\demo.ps1 start    # Switch back to Kubernetes and reopen its local URLs.
```

The same commands work in WSL as `bash demo.sh status`, `bash demo.sh scale 2`, etc.
Do not run `compose` and `start` simultaneously.

## Understand the files before explaining them

1. Read the [beginner guide](../docs/BEGINNER-GUIDE.md).
2. Follow the [interview walkthrough](../docs/INTERVIEW.md).
3. Read the commented [main.py](../app/main.py), [tasks.py](../app/tasks.py),
   [compose.yaml](../compose.yaml), and [ci.yml](../.github/workflows/ci.yml).
4. Compare the [cloud equivalents](../docs/CLOUD-ALTERNATIVES.md).

For manual Kubernetes/Terraform commands from the repository README, first run this
in **Ubuntu WSL** so your shell selects this demo's tools and kubeconfig:

```bash
source /mnt/c/Users/pcc20/Documents/Codex/2026-10-28/can-x20/outputs/mini-mlops/demo-env.sh
kubectl --context kind-mini-mlops -n mini-mlops get pods
```

Tools and kubeconfig are scoped to this workspace under `../../work/` relative to the repository; the helper
selects the pinned kubectl compatible with this cluster. It does not replace your
system kubectl installation. Keep `work/`, the local cluster container, and the ignored
Terraform state if you want to retain this prepared setup.

Background port-forward logs are in `../../work/forward-*.log` relative to the repository. If a page stops opening,
run `start` again. The GitHub workflow deploys to a temporary remote runner; these
helper commands manage the separate deployment on your laptop.
