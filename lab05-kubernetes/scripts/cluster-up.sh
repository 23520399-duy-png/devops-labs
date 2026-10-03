#!/usr/bin/env bash
# Dựng cluster kind + Calico + ingress-nginx + metrics-server. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"

if ! kind get clusters | grep -qx devops; then
  kind create cluster --config kind-config.yaml --wait 60s
fi
kubectl config use-context kind-devops

echo "==> Calico (CNI hỗ trợ NetworkPolicy)"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> ingress-nginx (bản dành cho kind)"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml >/dev/null
kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=300s

echo "==> metrics-server (cho kubectl top và HPA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait >/dev/null

kubectl get nodes -L topology.kubernetes.io/zone
echo "✅ Cluster sẵn sàng"
