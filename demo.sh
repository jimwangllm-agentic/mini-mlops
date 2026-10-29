#!/usr/bin/env bash
# Laptop-specific controls. Run this script inside Ubuntu WSL.
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
PROJECT="$BASE"
WORK=$(cd "${DEMO_WORK_DIR:-$BASE/../../work}" && pwd)
export PATH="$WORK/linux-bin:$PATH"
export KUBECONFIG="$WORK/kubeconfig"
export TF_VAR_kube_config="$KUBECONFIG"

forward_ports() {
  # Check HTTP readiness, not just an open TCP port: a tunnel to an old Pod can
  # briefly keep listening during a rollout, then exit on its next request.
  # Retry so a closed tunnel is recreated before reporting the demo ready.
  for item in api:8000 mlflow:5000 prometheus:9090 grafana:3000; do
    service=${item%:*}
    port=${item#*:}
    case "$service" in
      api|mlflow) health_path=/health ;;
      prometheus) health_path=/-/ready ;;
      grafana) health_path=/api/health ;;
    esac
    service_ready=false
    for attempt in {1..30}; do
      if ! python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$port"; then
        # nohup/disown keep this tunnel alive after the launching shell exits.
        nohup kubectl --context kind-mini-mlops -n mini-mlops port-forward "service/$service" "$port:$port" \
          > "$WORK/forward-$service.log" 2>&1 < /dev/null &
        disown "$!"
      fi
      if python3 -c 'import sys,urllib.request; urllib.request.urlopen(sys.argv[1],timeout=2).close()' "http://127.0.0.1:$port$health_path" 2>/dev/null; then
        service_ready=true
        echo "$service is reachable on localhost:$port"
        break
      fi
      sleep 1
    done
    if [[ "$service_ready" != true ]]; then
      echo "$service is not reachable. Check $WORK/forward-$service.log"
      return 1
    fi
  done
}

case "${1:-status}" in
  start)
    # Docker Desktop's Windows engine can become ready before its WSL socket.
    # Wait for the connection used by this Ubuntu shell before running Compose/kind.
    echo "Waiting for Docker Desktop's WSL connection..."
    engine_ready=false
    for attempt in {1..60}; do
      if docker info >/dev/null 2>&1; then
        engine_ready=true
        break
      fi
      sleep 2
    done
    if [[ "$engine_ready" != true ]]; then
      echo "Docker is unavailable in Ubuntu. Start Docker Desktop and enable this distribution's WSL integration, then retry."
      exit 1
    fi
    docker compose -f "$PROJECT/compose.yaml" down
    if docker container inspect mini-mlops-control-plane >/dev/null 2>&1; then
      docker start mini-mlops-control-plane >/dev/null
      # After a reboot, the container can be running before Kubernetes accepts
      # commands. Retry its readiness endpoint before checking Node/Pod readiness.
      cluster_ready=false
      for attempt in {1..90}; do
        if kubectl --context kind-mini-mlops get --raw=/readyz >/dev/null 2>&1; then
          cluster_ready=true
          break
        fi
        sleep 2
      done
      if [[ "$cluster_ready" != true ]]; then
        echo "Kubernetes did not become ready. Check Docker Desktop, then retry start."
        exit 1
      fi
      kubectl --context kind-mini-mlops wait --for=condition=Ready node --all --timeout=180s
    else
      (cd "$PROJECT" && bash scripts/deploy.sh)
    fi
    for service in api worker mlflow prometheus grafana; do
      kubectl --context kind-mini-mlops -n mini-mlops rollout status "deployment/$service" --timeout=300s
    done
    forward_ports
    echo "Demo URLs: API http://localhost:8000/docs | MLflow http://localhost:5000 | Grafana http://localhost:3000/d/iris-demo"
    ;;
  stop)
    # Stop the local node without deleting its models, jobs, or Terraform state.
    docker stop mini-mlops-control-plane
    ;;
  status)
    docker ps --format 'table {{.Names}}\t{{.Status}}'
    kubectl --context kind-mini-mlops -n mini-mlops get pods,services,pvc,jobs
    ;;
  smoke)
    python3 "$PROJECT/scripts/smoke.py"
    ;;
  scale)
    count=${2:-2}
    [[ "$count" =~ ^[1-4]$ ]] || { echo "Choose 1, 2, 3, or 4 workers for this laptop demo."; exit 1; }
    terraform -chdir="$PROJECT/terraform" apply -auto-approve -var="worker_replicas=$count"
    kubectl --context kind-mini-mlops -n mini-mlops rollout status deployment/worker --timeout=180s
    kubectl --context kind-mini-mlops -n mini-mlops get pods -l app=worker
    ;;
  infra)
    terraform -chdir="$PROJECT/terraform" plan
    ;;
  compose)
    if docker container inspect mini-mlops-control-plane >/dev/null 2>&1; then
      docker stop mini-mlops-control-plane >/dev/null
    fi
    docker compose -f "$PROJECT/compose.yaml" up -d --no-build
    ;;
  *) echo "Usage: bash demo.sh {start|stop|status|smoke|scale [1-4]|infra|compose}"; exit 1 ;;
esac
