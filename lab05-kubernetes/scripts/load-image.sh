#!/usr/bin/env bash
# Build image shopmini và nạp thẳng vào các node kind (không cần registry).
set -euo pipefail
TAG="${1:-lab05}"
docker build --build-arg APP_VERSION="$TAG" -t "shopmini:$TAG" "$(dirname "$0")/../../app"
kind load docker-image "shopmini:$TAG" --name devops
echo "→ shopmini:$TAG đã có trên mọi node"
