#!/usr/bin/env bash
# Tạo SealedSecret cho DB (mã hóa bằng public key của controller trong cluster) → an toàn để commit.
#   ./scripts/seal-db-secret.sh dev   |   ./scripts/seal-db-secret.sh prod
set -euo pipefail
ENV="${1:?dev|prod}"; NS="shop-$ENV"
OUT="$(dirname "$0")/../gitops/envs/$ENV/sealed-db.yaml"
PASS="${DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)}"
kubectl create secret generic shopmini-db -n "$NS" \
  --from-literal=username=shop --from-literal=password="$PASS" \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml > "$OUT"
echo "→ $OUT (mật khẩu KHÔNG được lưu ở đâu khác – Postgres khởi tạo lần đầu sẽ dùng nó)"
