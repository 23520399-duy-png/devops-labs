#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
PASS="${DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)}"
kubectl create secret generic shopmini-db -n shop-prod --from-literal=username=shop --from-literal=password="$PASS" \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml \
  > "$CAP_DIR/gitops/envs/aws/sealed-db.yaml"
echo "→ gitops/envs/aws/sealed-db.yaml – commit & push"
