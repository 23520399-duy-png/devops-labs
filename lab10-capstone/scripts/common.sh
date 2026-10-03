# shellcheck shell=bash
# Biến dùng chung cho các script capstone
export AWS_REGION="${AWS_REGION:-us-east-1}"
CAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_out() { terraform -chdir="$CAP_DIR/terraform/$1" output -raw "$2"; }
export KUBECONFIG="${KUBECONFIG_CAPSTONE:-$HOME/.kube/capstone.yaml}"
