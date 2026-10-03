#!/usr/bin/env bash
# Điền EIP và tên bucket (từ stack persistent) vào manifest GitOps. Chạy 1 lần, rồi commit.
set -euo pipefail
source "$(dirname "$0")/common.sh"
EIP=$(tf_out persistent eip_public_ip); BUCKET=$(tf_out persistent backup_bucket)
grep -rl EIP_PLACEHOLDER "$CAP_DIR/gitops" | xargs -r sed -i "s/EIP_PLACEHOLDER/$EIP/g"
grep -rl BUCKET_PLACEHOLDER "$CAP_DIR/gitops" | xargs -r sed -i "s/BUCKET_PLACEHOLDER/$BUCKET/g"
echo "→ shop.$EIP.nip.io · bucket $BUCKET. Nhớ: git commit && git push"
