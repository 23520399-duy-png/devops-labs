#!/usr/bin/env bash
# Tạo/xóa 2 "server" giả lập bằng container để luyện Ansible không tốn tiền.
#   ./scripts/local-targets.sh up | down | reset
set -euo pipefail
case "${1:-up}" in
  up)
    docker run -d --name web-ubuntu --hostname web-ubuntu ubuntu:24.04 sleep infinity >/dev/null 2>&1 || true
    docker run -d --name web-al2023 --hostname web-al2023 amazonlinux:2023 sleep infinity >/dev/null 2>&1 || true
    # Ansible cần Python trên máy đích → cài bằng lệnh "thô" (giống module raw)
    docker exec web-ubuntu bash -c 'command -v python3 >/dev/null || (apt-get update -qq && apt-get install -y -qq python3 >/dev/null)'
    docker exec web-al2023 bash -c 'command -v python3 >/dev/null || dnf install -y -q python3 >/dev/null'
    docker ps --filter name=web- --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    ;;
  down)  docker rm -f web-ubuntu web-al2023 ;;
  reset) "$0" down; "$0" up ;;
  *) echo "usage: $0 up|down|reset"; exit 1 ;;
esac
