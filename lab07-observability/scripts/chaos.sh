#!/usr/bin/env bash
# Bơm lỗi vào MỌI pod api (chaos state nằm trong từng process).
#   ./scripts/chaos.sh shop-dev 0.3 0      → 30% request lỗi 500
#   ./scripts/chaos.sh shop-dev 0 800      → +800ms latency
#   ./scripts/chaos.sh shop-dev 0 0        → tắt chaos
set -euo pipefail
NS="${1:-shop-dev}"; ERR="${2:-0}"; LAT="${3:-0}"
for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/component=api -o name); do
  kubectl -n "$NS" exec "$p" -- python -c "import urllib.request as u; print(u.urlopen(u.Request('http://localhost:8000/chaos?error_rate=$ERR&latency_ms=$LAT', method='POST')).read().decode())"
done
