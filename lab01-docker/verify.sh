#!/usr/bin/env bash
# Lab 01 – tự chấm. Chạy từ thư mục lab01-docker sau khi: docker compose up -d --build
# QUICK=1 ./verify.sh  → bỏ qua bài test tải k6 (~90s)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd docker jq curl
IMG="shopmini:lab01"
BASE="http://localhost:8080"

section "Image"
if docker image inspect "$IMG" >/dev/null 2>&1; then
  pass "image $IMG tồn tại"
  size_mb=$(( $(docker image inspect -f '{{.Size}}' "$IMG") / 1024 / 1024 ))
  if [ "$size_mb" -lt 200 ]; then pass "kích thước ${size_mb} MB < 200 MB"; else fail "kích thước ${size_mb} MB ≥ 200 MB"; fi
  user=$(docker image inspect -f '{{.Config.User}}' "$IMG")
  case "$user" in ""|root|0|0:0) fail "image chạy bằng root (USER='$user')";; *) pass "chạy bằng user non-root ($user)";; esac
  if [ "$(docker image inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$IMG")" = "yes" ]; then pass "có HEALTHCHECK"; else fail "thiếu HEALTHCHECK"; fi
  if docker image inspect -f '{{json .Config.Env}}' "$IMG" | grep -qiE 'password|secret'; then fail "image chứa secret trong ENV"; else pass "không có secret trong ENV"; fi
  if docker image inspect -f '{{json .Config.Cmd}}{{json .Config.Entrypoint}}' "$IMG" | grep -q -- '--reload'; then fail "đang chạy --reload (chế độ dev)"; else pass "không dùng --reload"; fi
  if docker run --rm --entrypoint sh "$IMG" -c 'command -v pytest || command -v gcc' >/dev/null 2>&1; then fail "image còn công cụ build/test (pytest/gcc)"; else pass "không chứa pytest/gcc"; fi
  if command -v trivy >/dev/null; then
    if trivy image -q --severity CRITICAL --ignore-unfixed --exit-code 1 "$IMG" >/dev/null 2>&1; then pass "trivy: 0 CVE CRITICAL (fixable)"; else fail "trivy phát hiện CVE CRITICAL"; fi
  else warn "chưa cài trivy – bỏ qua quét CVE"; fi
else fail "chưa có image $IMG (docker compose build)"; fi

section "Compose stack"
for svc in db cache api nginx; do
  cid=$(docker compose ps -q "$svc" 2>/dev/null)
  st=$( [ -n "$cid" ] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
  if [ "$st" = "healthy" ]; then pass "$svc: healthy"; else fail "$svc: '${st:-không chạy}' (cần healthy)"; fi
done
check "GET /readyz qua nginx = 200" curl -fsS "$BASE/readyz"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/metrics"); [ "$code" = "404" ] && pass "/metrics không bị public ($code)" || fail "/metrics đang public ($code)"
if curl -s --max-time 2 http://localhost:8000/healthz >/dev/null 2>&1; then fail "api đang publish port 8000 ra host"; else pass "api không publish port ra host"; fi
if docker compose exec -T api sh -c 'touch /app/x' >/dev/null 2>&1; then fail "root filesystem của api vẫn ghi được"; else pass "api chạy read-only root filesystem"; fi
if docker compose exec -T api sh -c 'touch /tmp/x' >/dev/null 2>&1; then pass "/tmp ghi được (tmpfs)"; else fail "/tmp không ghi được – thiếu tmpfs"; fi
caps=$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$(docker compose ps -q api)")
echo "$caps" | grep -q ALL && pass "api drop toàn bộ Linux capabilities" || fail "api chưa cap_drop: [ALL]"

section "Độ bền (resilience)"
start=$(date +%s); docker compose stop -t 30 api >/dev/null 2>&1; dur=$(( $(date +%s) - start ))
if [ "$dur" -le 10 ]; then pass "api dừng gọn trong ${dur}s (nhận SIGTERM đúng)"; else fail "api mất ${dur}s mới dừng → CMD dạng shell / PID 1 không nhận SIGTERM?"; fi
docker compose start api >/dev/null 2>&1
retry 30 2 sh -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' \$(docker compose ps -q api))\" = healthy ]" && pass "api healthy lại sau khi start" || fail "api không healthy lại"
docker compose exec -T api python -c 'import os,signal; os.kill(1, signal.SIGTERM)' >/dev/null 2>&1
sleep 3
retry 30 2 curl -fsS "$BASE/readyz" && pass "api tự khởi động lại sau khi process chết (restart policy)" || fail "api không tự khởi động lại"
oid=$(curl -fsS -X POST "$BASE/orders" -H 'content-type: application/json' -d '{"customer":"verify","item":"persist","quantity":1,"price":1}' | jq -r .id)
docker compose down >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1
retry 45 2 curl -fsS "$BASE/readyz" >/dev/null
if curl -fsS "$BASE/orders/$oid" 2>/dev/null | grep -q persist; then pass "dữ liệu còn sau docker compose down/up (volume)"; else fail "mất dữ liệu sau down/up"; fi

section "Hiệu năng"
if [ "${QUICK:-0}" = "1" ]; then warn "QUICK=1 – bỏ qua k6"
elif command -v k6 >/dev/null; then
  if k6 run -q loadtest/k6-load.js >/tmp/k6-lab01.txt 2>&1; then pass "k6: p95 < 200ms và lỗi < 1% ở 50 VU"
  else fail "k6 không đạt threshold – xem /tmp/k6-lab01.txt"; fi
else warn "chưa cài k6"; fi

summary
