#!/usr/bin/env bash
# Cài kube-prometheus-stack + Loki + Alloy + alert-receiver vào namespace monitoring.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
kubectl config use-context kind-devops
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "==> kube-prometheus-stack"
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring -f helm/kube-prometheus-stack.yaml --wait --timeout 10m
echo "==> Loki"
helm upgrade --install loki grafana/loki -n monitoring -f helm/loki.yaml --wait --timeout 10m
echo "==> Alloy"
helm upgrade --install alloy grafana/alloy -n monitoring -f helm/alloy.yaml --wait
echo "==> alert-receiver + dashboard"
kubectl apply -f scripts/alert-receiver.yaml
kubectl -n monitoring create configmap shopmini-dashboard --from-file=dashboards/shopmini-red.json \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
cat <<MSG
✅ Xong.
  Grafana      : http://grafana.127.0.0.1.nip.io   (admin / devops-labs)
  Prometheus   : http://prometheus.127.0.0.1.nip.io
  Alertmanager : http://alertmanager.127.0.0.1.nip.io
  Alert log    : kubectl -n monitoring logs -f deploy/alert-receiver
MSG
