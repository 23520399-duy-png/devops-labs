#!/usr/bin/env bash
# Lab 07 – tự chấm.  FIRE=1 để bơm lỗi và chờ alert bắn (~6 phút)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd kubectl jq curl
NS="${NS:-shop-dev}"
PROM="http://prometheus.127.0.0.1.nip.io"
GRAF="http://admin:devops-labs@grafana.127.0.0.1.nip.io"
q() { curl -fsS --get "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result'; }

section "Stack giám sát"
for d in kps-operator kps-grafana kps-kube-state-metrics alert-receiver; do
  check "deploy/$d chạy" kubectl -n monitoring rollout status "deploy/$d" --timeout=5s
done
check "Prometheus sẵn sàng" curl -fsS "$PROM/-/ready"
check "Loki sẵn sàng" kubectl -n monitoring rollout status sts/loki --timeout=5s
check "Alloy chạy trên mọi node" kubectl -n monitoring rollout status ds/alloy --timeout=5s

section "Metric của shopmini"
up=$(q "sum(up{job=\"shopmini\",namespace=\"$NS\"})" | jq -r '.[0].value[1] // "0"')
[ "${up%.*}" -ge 1 ] && pass "Prometheus scrape được $up pod shopmini ($NS)" || fail "không scrape được shopmini – ServiceMonitor / NetworkPolicy?"
for r in shopmini:request_errors:ratio_rate5m shopmini:request_duration_seconds:p95_5m; do
  n=$(q "$r{namespace=\"$NS\"}" | jq 'length')
  [ "$n" -ge 1 ] && pass "recording rule $r có dữ liệu" || fail "recording rule $r chưa có dữ liệu (có traffic chưa?)"
done
rules=$(curl -fsS "$PROM/api/v1/rules" | jq '[.data.groups[].rules[] | select(.type=="alerting") | .name] | map(select(startswith("Shopmini"))) | length')
[ "$rules" -ge 4 ] && pass "$rules alert rule Shopmini* đã nạp" || fail "chỉ có $rules alert rule Shopmini*"

section "Grafana & Loki"
curl -fsS "$GRAF/api/search?query=shopmini" | jq -e 'length>=1' >/dev/null && pass "dashboard shopmini đã có trong Grafana" || fail "chưa thấy dashboard shopmini"
logs=$(curl -fsS --get "$GRAF/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={namespace=\"$NS\", app=\"shopmini\"}" --data-urlencode "limit=5" 2>/dev/null | jq '.data.result | length')
[ "${logs:-0}" -ge 1 ] && pass "Loki có log của shopmini ($NS)" || fail "Loki chưa có log shopmini"
grep -q "TODO" RUNBOOK.md && warn "RUNBOOK.md còn TODO (Bài 6)" || pass "RUNBOOK.md đã hoàn thiện"

section "Alert end-to-end (FIRE=1)"
if [ "${FIRE:-0}" = "1" ]; then
  ./scripts/chaos.sh "$NS" 0.3 0 >/dev/null
  BASE_URL="http://shop.127.0.0.1.nip.io" VUS=15 DURATION=6m k6 run -q "$ROOT/lab05-kubernetes/loadtest/k6-k8s.js" >/dev/null 2>&1 &
  K6=$!; start=$(date +%s); fired=0
  while [ $(( $(date +%s) - start )) -lt 420 ]; do
    if kubectl -n monitoring logs deploy/alert-receiver --since=10m 2>/dev/null | grep -q '"alertname": "ShopminiErrorBudgetBurnFast".*"status": "firing"\|"status": "firing", "alertname": "ShopminiErrorBudgetBurnFast"'; then fired=1; break; fi
    sleep 15
  done
  el=$(( $(date +%s) - start ))
  ./scripts/chaos.sh "$NS" 0 0 >/dev/null; kill $K6 2>/dev/null
  [ "$fired" = "1" ] && pass "alert ShopminiErrorBudgetBurnFast tới người trực sau ${el}s" || fail "alert không tới receiver trong 7 phút"
  [ "$fired" = "1" ] && [ "$el" -le 300 ] && pass "thời gian phát hiện ≤ 5 phút" || warn "thời gian phát hiện > 5 phút – tinh chỉnh 'for' / group_wait?"
else warn "bỏ qua – FIRE=1 ./verify.sh"; fi

summary
