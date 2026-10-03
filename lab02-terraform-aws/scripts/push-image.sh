#!/usr/bin/env bash
# Build image shopmini và push lên ECR. Dùng: ./push-image.sh <tag>   (mặc định: lab02)
set -euo pipefail
TAG="${1:-lab02}"
REGION="${AWS_REGION:-us-east-1}"
cd "$(dirname "$0")/../envs/dev" || exit 1
REPO="$(terraform output -raw ecr_repository_url)"
REGISTRY="${REPO%%/*}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker build --build-arg APP_VERSION="$TAG" -t "$REPO:$TAG" ../../../app
docker push "$REPO:$TAG"
echo "→ Đã push $REPO:$TAG"
aws ecr describe-image-scan-findings --repository-name shopmini --image-id imageTag="$TAG" \
  --query 'imageScanFindings.findingSeverityCounts' --output table 2>/dev/null || echo "(scan đang chạy…)"
