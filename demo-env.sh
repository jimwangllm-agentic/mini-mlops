# Source this file in Ubuntu WSL to use this laptop's demo tools and cluster.
# It changes this shell's directory and environment; it does not start/stop services.
DEMO_OUTPUTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_WORK=$(cd "${DEMO_WORK_DIR:-$DEMO_OUTPUTS/../../work}" && pwd)
export PATH="$DEMO_WORK/linux-bin:$PATH"
export KUBECONFIG="$DEMO_WORK/kubeconfig"
export TF_VAR_kube_config="$KUBECONFIG"
cd "$DEMO_OUTPUTS"
