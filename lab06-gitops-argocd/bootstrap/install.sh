#!/usr/bin/env bash
# Cài Argo CD + Argo Rollouts + Sealed Secrets lên cluster kind "devops" (Lab 05), rồi tạo root app.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
kubectl config use-context kind-devops

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> Argo CD"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f argocd-values.yaml --wait

echo "==> Argo Rollouts (+ dashboard)"
helm upgrade --install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace \
  --set dashboard.enabled=true --wait

echo "==> Sealed Secrets controller"
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system \
  --set fullnameOverride=sealed-secrets-controller --wait

echo "==> Root application (app-of-apps)"
kubectl apply -f root-app.yaml

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
cat <<MSG

✅ Xong.
  UI Argo CD : http://argocd.127.0.0.1.nip.io   (user: admin / pass: $PASS)
  CLI        : argocd login argocd.127.0.0.1.nip.io --grpc-web --username admin --password '$PASS' --insecure
  Rollouts   : kubectl argo rollouts dashboard   → http://localhost:3100
MSG
