#!/usr/bin/env bash
# Sao lưu private key của Sealed Secrets controller lên S3 (mã hóa SSE). Chạy sau lần dựng đầu tiên.
set -euo pipefail
source "$(dirname "$0")/common.sh"
BUCKET=$(tf_out persistent backup_bucket)
# Bỏ uid/resourceVersion/... để có thể apply vào cluster MỚI
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o json \
  | jq '.items[].metadata |= {name, namespace, labels}' \
  | aws s3 cp - "s3://$BUCKET/sealed-secrets/key.yaml" --sse AES256
echo "✔ đã backup key lên s3://$BUCKET/sealed-secrets/key.yaml"
