#!/usr/bin/env bash
# Lab 04 – tự chấm (cần GitHub CLI: gh auth login)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd gh jq git
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -n "$REPO" ] || { fail "không xác định được repo GitHub (gh auth login? remote origin?)"; summary; exit 1; }
OWNER=${REPO%%/*}

section "Cấu hình trong repo"
check ".github/workflows/ci.yml tồn tại" test -f "$ROOT/.github/workflows/ci.yml"
check ".github/dependabot.yml tồn tại" test -f "$ROOT/.github/dependabot.yml"
check "có PR template" test -f "$ROOT/.github/pull_request_template.md"
if command -v actionlint >/dev/null; then check "actionlint không lỗi" actionlint "$ROOT/.github/workflows/ci.yml"; else warn "chưa cài actionlint (go install github.com/rhysd/actionlint/cmd/actionlint@latest)"; fi
grep -q "cov-fail-under=8[5-9]\|cov-fail-under=9" "$ROOT/.github/workflows/ci.yml" && pass "coverage gate ≥ 85% (Bài 3)" || fail "coverage gate chưa nâng lên ≥ 85% (Bài 3)"
grep -q "permissions:" "$ROOT/.github/workflows/ci.yml" && pass "workflow khai báo permissions tối thiểu" || fail "thiếu permissions"

section "Lần chạy CI gần nhất trên main"
run=$(gh run list -R "$REPO" --workflow ci.yml --branch main --limit 1 --json conclusion,createdAt,updatedAt,databaseId 2>/dev/null | jq '.[0]')
if [ "$run" != "null" ] && [ -n "$run" ]; then
  concl=$(echo "$run" | jq -r .conclusion)
  [ "$concl" = "success" ] && pass "ci trên main: success" || fail "ci trên main: $concl"
  dur=$(( $(date -d "$(echo "$run" | jq -r .updatedAt)" +%s) - $(date -d "$(echo "$run" | jq -r .createdAt)" +%s) ))
  [ "$dur" -lt 360 ] && pass "thời gian pipeline ${dur}s < 6 phút" || fail "pipeline chạy ${dur}s ≥ 6 phút (tối ưu cache?)"
else fail "chưa có lần chạy ci.yml nào trên main"; fi

section "Image trên GHCR"
tags=$(gh api "users/$OWNER/packages/container/shopmini/versions" --jq '.[].metadata.container.tags[]' 2>/dev/null || gh api "orgs/$OWNER/packages/container/shopmini/versions" --jq '.[].metadata.container.tags[]' 2>/dev/null)
echo "$tags" | grep -q '^sha-' && pass "có image tag sha-<commit>" || fail "chưa có tag sha-* trên GHCR"
echo "$tags" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && pass "có image tag semver (đã tạo release vX.Y.Z)" || fail "chưa có tag semver – tạo git tag v1.0.0 (Bài 5)"
gh release view -R "$REPO" >/dev/null 2>&1 && pass "có GitHub Release" || fail "chưa có GitHub Release"

section "Bảo vệ nhánh main"
prot=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null)
if [ -n "$prot" ]; then
  echo "$prot" | jq -e '.required_status_checks.contexts | length > 0' >/dev/null 2>&1 \
    || echo "$prot" | jq -e '.required_status_checks.checks | length > 0' >/dev/null 2>&1 \
    && pass "main yêu cầu status check trước khi merge" || fail "main chưa bắt buộc status check"
  echo "$prot" | jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1 && pass "main yêu cầu Pull Request" || warn "main chưa bắt buộc PR (repo cá nhân có thể bỏ review)"
else
  rules=$(gh api "repos/$REPO/rules/branches/main" 2>/dev/null | jq -r '.[].type' | tr '\n' ' ')
  echo "$rules" | grep -q required_status_checks && pass "ruleset main yêu cầu status check" || fail "chưa bật branch protection / ruleset cho main"
fi

section "Bằng chứng PR bị chặn"
gh pr list -R "$REPO" --state all --search "label:lab04-red" --json number -q 'length' 2>/dev/null | grep -qv '^0$' \
  && pass "có PR gắn label lab04-red (PR cố ý làm test fail)" || fail "chưa có PR 'đỏ' gắn label lab04-red (Bài 4)"

summary
