#!/usr/bin/env bash
# Cài Kyverno và áp dụng policy (thay YOUR_GITHUB_USER trước khi chạy: ../lab06-gitops-argocd/scripts/set-repo.sh).
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
grep -rq YOUR_GITHUB_USER policies && { echo "Còn YOUR_GITHUB_USER trong policies/ – sed trước đã"; exit 1; }
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set admissionController.replicas=1 --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 --set reportsController.replicas=1 --wait
kubectl apply -f policies/ -f policies/cluster-only/
kubectl get clusterpolicy
