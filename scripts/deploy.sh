#!/usr/bin/env bash
# Run this script with Bash: bash scripts/deploy.sh
# -e stops on command errors; -u rejects unset variables; pipefail catches pipeline errors.
set -euo pipefail
# $0 is this script; dirname finds its folder; /.. selects the project root.
cd "$(dirname "$0")/.."
# Use the caller's IMAGE variable if supplied; otherwise use our local demo tag.
IMAGE="${IMAGE:-mini-mlops:local}"
# Terraform reads TF_VAR_image as the input variable named image.
export TF_VAR_image="$IMAGE"
# kind creates the local cluster; Terraform provisions services and storage inside it.
# '|' sends cluster names to grep; -qx requires an exact full-line match.
# '!' means NOT: create the cluster only if this name is not already listed.
if ! kind get clusters | grep -qx mini-mlops; then
  # --name identifies our cluster; --image selects its Kubernetes node version.
  # --wait 120s gives the control plane time to become ready.
  kind create cluster --name mini-mlops --image kindest/node:v1.32.2 --wait 120s
fi
# Build the Dockerfile in '.', tagging the resulting image with $IMAGE.
docker build -t "$IMAGE" .
# kind has its own container runtime: copy the laptop/runner image into its node.
kind load docker-image "$IMAGE" --name mini-mlops
# -chdir selects the Terraform folder. init downloads the Kubernetes provider.
# -input=false prevents interactive prompts (important on GitHub Actions runners).
terraform -chdir=terraform init -input=false
# apply creates/updates declared resources; -auto-approve skips the approval prompt.
# The provider targets the kind-mini-mlops context, creating our demo namespace/resources.
terraform -chdir=terraform apply -auto-approve -input=false
# Loop over services, waiting until each Deployment has its requested ready Pods.
# --context chooses the cluster; -n chooses its namespace; --timeout limits waiting.
for service in postgres redis mlflow api worker prometheus grafana; do
  kubectl --context kind-mini-mlops -n mini-mlops rollout status deployment/"$service" --timeout=300s
done
# A one-off Kubernetes training Job, using the same image as inference.
# date +%s produces a timestamp, making this training Job's name distinct.
job="train-$(date +%s)"
# Build a Job description locally first: --dry-run=client means do not create it yet.
# -o yaml prints that description. After '--' is the container's startup command.
# The pipes send the description through these three commands:
# 1. create job --dry-run: generate a Job that runs python -m app.train.
# 2. set env --local -f -: read YAML from stdin, add MLflow's URL, print updated YAML.
# 3. create -f -: send the final description to Kubernetes and actually start the Job.
# Editing the environment BEFORE creation matters: a Job's Pod template is immutable.
kubectl --context kind-mini-mlops -n mini-mlops create job "$job" --image="$IMAGE" --dry-run=client -o yaml -- python -m app.train |
  kubectl set env --local -f - MLFLOW_TRACKING_URI=http://mlflow:5000 -o yaml |
  kubectl --context kind-mini-mlops -n mini-mlops create -f -
# Wait for successful training, not just a running container. If it does not
# complete in five minutes, print training logs and exit with failure code 1.
if ! kubectl --context kind-mini-mlops -n mini-mlops wait --for=condition=complete job/"$job" --timeout=300s; then
  kubectl --context kind-mini-mlops -n mini-mlops logs job/"$job" --all-containers=true
  exit 1
fi
# Print the successful training output (registered version and accuracy).
kubectl --context kind-mini-mlops -n mini-mlops logs job/"$job"
echo "Deployment ready. See README for port-forward commands."
