#!/usr/bin/env bash
# Build & push image lên ECR của Lab 09 (repo IMMUTABLE → mỗi lần push phải dùng tag MỚI)
#   ./scripts/push-image.sh lab09-v2
set -euo pipefail
TAG="${1:?tag mới, vd lab09-v2}"
cd "$(dirname "$0")/../terraform" || exit 1
REPO="$(terraform output -raw ecr_repository_url)"
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --build-arg APP_VERSION="$TAG" -t "$REPO:$TAG" ../../app
docker push "$REPO:$TAG"
echo "→ terraform apply -var image_tag=$TAG"
