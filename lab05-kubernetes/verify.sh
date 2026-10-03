#!/usr/bin/env bash
# Lab 05 – tự chấm.  NS=shop-dev ./verify.sh   ·   FULL=1 để chạy thêm rollout dưới tải + HPA (~6 phút)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd kubectl jq curl
NS="${NS:-shop-dev}"
HOST="${HOST:-shop.127.0.0.1.nip.io}"

section "Cluster"
ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
[ "$ready" -ge 4 ] && pass "$ready node Ready" || fail "chỉ $ready node Ready (cần 4)"
check "Calico chạy" kubectl -n kube-system rollout status ds/calico-node --timeout=5s
check "ingress-nginx chạy" kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5s
check "metrics-server trả số liệu" kubectl top nodes

section "Workload trong $NS"
[ "$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = "restricted" ] \
  && pass "namespace enforce Pod Security 'restricted'" || fail "namespace chưa enforce restricted"
check "deployment shopmini Available" kubectl -n "$NS" rollout status deploy/shopmini --timeout=10s
check "statefulset postgres sẵn sàng" kubectl -n "$NS" rollout status sts/postgres --timeout=10s
check "redis sẵn sàng" kubectl -n "$NS" rollout status deploy/redis --timeout=10s
pods=$(kubectl -n "$NS" get pods -o json)
nores=$(echo "$pods" | jq '[.items[].spec.containers[] | select(.resources.requests==null or .resources.limits==null)] | length')
[ "$nores" = "0" ] && pass "mọi container có requests + limits" || fail "$nores container thiếu requests/limits"
noprobe=$(echo "$pods" | jq '[.items[] | select(.metadata.labels["app.kubernetes.io/component"]=="api") | .spec.containers[] | select(.readinessProbe==null or .livenessProbe==null)] | length')
[ "$noprobe" = "0" ] && pass "api có readiness + liveness probe" || fail "api thiếu probe"
zones=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=api -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort -u | wc -l)
[ "$zones" -ge 2 ] && pass "pod api trải trên $zones zone" || fail "pod api chỉ ở $zones zone"
restarts=$(echo "$pods" | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0')
[ "$restarts" -le 3 ] && pass "tổng restart = $restarts (ổn định)" || warn "tổng restart = $restarts – xem kubectl describe"
check "PDB tồn tại" kubectl -n "$NS" get pdb shopmini
check "HPA tồn tại" kubectl -n "$NS" get hpa shopmini

section "Truy cập qua Ingress"
r=$(curl -fsS --max-time 5 "http://$HOST/readyz")
echo "$r" | jq -e '.checks.database=="ok"' >/dev/null 2>&1 && pass "/readyz: database ok" || fail "/readyz database lỗi"
echo "$r" | jq -e '.checks.redis=="ok"' >/dev/null 2>&1 && pass "/readyz: redis ok (đã viết NetworkPolicy cho redis)" || fail "/readyz: redis chưa ok → Bài 4"

section "NetworkPolicy"
np=$(./tests/netpol-test.sh "$NS" 2>/dev/null)
echo "$np" | grep "pod lạ → postgres" | grep -q BLOCKED && pass "pod lạ KHÔNG vào được postgres" || fail "pod lạ vào được postgres"
echo "$np" | grep "pod lạ → redis" | grep -q BLOCKED && pass "pod lạ KHÔNG vào được redis" || fail "pod lạ vào được redis"
echo "$np" | grep "api → postgres" | grep -q OK && pass "api → postgres được phép" || fail "api → postgres bị chặn"
echo "$np" | grep "api → 1.1.1.1" | grep -q BLOCKED && pass "api không ra được internet (egress bị chặn)" || fail "api ra được internet"

section "Zero-downtime & HPA (FULL=1)"
if [ "${FULL:-0}" = "1" ] && command -v k6 >/dev/null; then
  BASE_URL="http://$HOST" VUS=20 DURATION=90s k6 run -q loadtest/k6-k8s.js >/tmp/lab05-rollout.txt 2>&1 &
  K6=$!; sleep 15
  kubectl -n "$NS" rollout restart deploy/shopmini >/dev/null && kubectl -n "$NS" rollout status deploy/shopmini --timeout=180s >/dev/null
  wait $K6 && pass "rollout restart dưới tải: lỗi < 1%" || fail "rớt request khi rollout – xem /tmp/lab05-rollout.txt"
  BASE_URL="http://$HOST" VUS=60 SLEEP=0 DURATION=3m k6 run -q loadtest/k6-k8s.js >/tmp/lab05-hpa.txt 2>&1 &
  K6=$!; max=0
  for _ in $(seq 1 18); do sleep 10; n=$(kubectl -n "$NS" get hpa shopmini -o jsonpath='{.status.currentReplicas}'); [ "${n:-0}" -gt "$max" ] && max=$n; done
  wait $K6 || true
  [ "$max" -ge 4 ] && pass "HPA scale lên $max pod dưới tải" || fail "HPA chỉ lên $max pod (cần ≥ 4)"
else warn "bỏ qua – chạy FULL=1 ./verify.sh"; fi

summary
