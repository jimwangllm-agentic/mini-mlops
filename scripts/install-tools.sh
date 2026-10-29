#!/usr/bin/env bash
# Run inside Ubuntu WSL. Installs pinned demo tools from official distributions.
set -euo pipefail
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip git python3
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "Unsupported architecture"; exit 1 ;;
esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
curl -fsSLo kind "https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-$arch"
sudo install -m 0755 kind /usr/local/bin/kind
curl -fsSLo kubectl "https://dl.k8s.io/release/v1.32.2/bin/linux/$arch/kubectl"
curl -fsSLo kubectl.sha256 "https://dl.k8s.io/release/v1.32.2/bin/linux/$arch/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -m 0755 kubectl /usr/local/bin/kubectl
tfzip="terraform_1.11.4_linux_$arch.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/1.11.4/$tfzip"
curl -fsSLo sums "https://releases.hashicorp.com/terraform/1.11.4/terraform_1.11.4_SHA256SUMS"
grep " $tfzip$" sums | sha256sum --check
unzip -q "$tfzip"
sudo install -m 0755 terraform /usr/local/bin/terraform
kind version
kubectl version --client
terraform version
docker version
docker compose version
