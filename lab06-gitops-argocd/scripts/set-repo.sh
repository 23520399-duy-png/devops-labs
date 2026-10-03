#!/usr/bin/env bash
# Thay YOUR_GITHUB_USER bằng user GitHub của bạn trong mọi lab (trừ README).
set -euo pipefail
U="${1:?github-username}"
cd "$(dirname "$0")/../.." || exit 1
grep -rl --exclude=README.md YOUR_GITHUB_USER lab0* lab1* | xargs -r sed -i "s/YOUR_GITHUB_USER/$U/g"
echo "→ Đã thay bằng $U. Nhớ commit & push."
