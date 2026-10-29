#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mini-mlops:local}"
export TF_VAR_image="$IMAGE"
# kind creates the local cluster; Terraform provisions everything inside it.
if ! kind get clusters | grep -qx mini-mlops; then
  kind create cluster --name mini-mlops --image kindest/node:v1.32.2 --wait 120s
fi
docker build -t "$IMAGE" .
kind load docker-image "$IMAGE" --name mini-mlops
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -auto-approve -input=false
for service in postgres redis mlflow api worker prometheus grafana; do
  kubectl --context kind-mini-mlops -n mini-mlops rollout status deployment/"$service" --timeout=300s
done
# A one-off Kubernetes training Job, using the same image as inference.
job="train-$(date +%s)"
kubectl --context kind-mini-mlops -n mini-mlops create job "$job" --image="$IMAGE" --dry-run=client -o yaml -- python -m app.train |
  kubectl set env --local -f - MLFLOW_TRACKING_URI=http://mlflow:5000 -o yaml |
  kubectl --context kind-mini-mlops -n mini-mlops create -f -
if ! kubectl --context kind-mini-mlops -n mini-mlops wait --for=condition=complete job/"$job" --timeout=300s; then
  kubectl --context kind-mini-mlops -n mini-mlops logs job/"$job" --all-containers=true
  exit 1
fi
kubectl --context kind-mini-mlops -n mini-mlops logs job/"$job"
echo "Deployment ready. See README for port-forward commands."
