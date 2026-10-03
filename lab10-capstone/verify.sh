#!/usr/bin/env bash
# Lab 10 (Capstone) – tự chấm toàn bộ "Definition of Done"
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
source scripts/common.sh
need_cmd terraform kubectl aws jq curl

section "Hạ tầng"
EIP=$(tf_out persistent eip_public_ip 2>/dev/null); BUCKET=$(tf_out persistent backup_bucket 2>/dev/null)
[ -n "$EIP" ] && pass "stack persistent: EIP $EIP, bucket $BUCKET" || fail "chưa apply stack persistent"
MYIP="$(curl -s https://checkip.amazonaws.com)/32"
terraform -chdir=terraform/persistent plan -detailed-exitcode -input=false >/tmp/lab10-persistent.txt 2>&1; rc=$?
[ $rc -eq 0 ] && pass "persistent: plan No changes" || fail "persistent: plan rc=$rc (/tmp/lab10-persistent.txt)"
terraform -chdir=terraform/cluster plan -detailed-exitcode -input=false -var my_ip="$MYIP" \
  -var eip_allocation_id="$(tf_out persistent eip_allocation_id)" -var eip_public_ip="$EIP" >/tmp/lab10-cluster.txt 2>&1; rc=$?
[ $rc -eq 0 ] && pass "cluster: plan No changes" || fail "cluster: plan rc=$rc (/tmp/lab10-cluster.txt)"
nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
[ "$nodes" -ge 3 ] && pass "$nodes node k3s Ready" || fail "chỉ $nodes node Ready"

section "GitOps"
bad=$(kubectl -n argocd get applications -o json 2>/dev/null | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | .metadata.name')
total=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)
[ "$total" -ge 5 ] && [ -z "$bad" ] && pass "$total Application đều Synced/Healthy" || fail "Application chưa ổn: ${bad:-không có app}"
grep -rq "EIP_PLACEHOLDER\|BUCKET_PLACEHOLDER\|YOUR_GITHUB_USER" gitops && fail "còn placeholder trong gitops/" || pass "đã điền placeholder"
kubectl get clusterpolicy >/dev/null 2>&1 && [ "$(kubectl get clusterpolicy --no-headers | wc -l)" -ge 4 ] \
  && pass "Kyverno policy (Lab 08) chạy trên cluster AWS" || fail "chưa đưa Kyverno + policy vào capstone (yêu cầu C3)"

section "Ứng dụng & giám sát"
r=$(curl -fsS --max-time 5 "http://shop.$EIP.nip.io/readyz" 2>/dev/null)
echo "$r" | jq -e '.status=="ready"' >/dev/null 2>&1 && pass "http://shop.$EIP.nip.io/readyz ready" || fail "app không sẵn sàng qua ingress"
kubectl -n monitoring get prometheusrule -A 2>/dev/null | grep -q shopmini-slo && pass "SLO rules đã nạp" || fail "thiếu PrometheusRule shopmini-slo"
curl -fsS --max-time 5 "http://grafana.$EIP.nip.io/api/health" >/dev/null 2>&1 && pass "Grafana truy cập được" || fail "Grafana không truy cập được"

section "Backup & DR"
aws s3 ls "s3://$BUCKET/sealed-secrets/key.yaml" >/dev/null 2>&1 && pass "đã backup key Sealed Secrets" || fail "chưa backup key Sealed Secrets"
last=$(aws s3 ls "s3://$BUCKET/db/" 2>/dev/null | sort | tail -1 | awk '{print $1" "$2}')
if [ -n "$last" ]; then
  age=$(( $(date +%s) - $(date -d "$last" +%s) ))
  [ "$age" -le 3600 ] && pass "DB backup mới nhất cách đây $((age/60)) phút (≤ 60)" || fail "backup mới nhất đã $((age/60)) phút"
else fail "chưa có DB backup trên S3"; fi
log=$(ls -t evidence/dr-drill-*.log 2>/dev/null | head -1)
if [ -n "$log" ]; then
  rto=$(sed -n 's/^RTO_SECONDS=//p' "$log"); rpo=$(sed -n 's/^RPO_SECONDS=//p' "$log")
  [ "${rto:-99999}" -le 1800 ] && pass "DR drill: RTO ${rto}s ≤ 30 phút" || fail "DR drill: RTO ${rto:-?}s > 30 phút"
  [ "${rpo:-99999}" -le 3600 ] && pass "DR drill: RPO ${rpo}s ≤ 1 giờ" || fail "DR drill: RPO ${rpo:-?}s > 1 giờ"
else fail "chưa chạy scripts/dr-drill.sh (evidence/dr-drill-*.log)"; fi

section "Tài liệu (portfolio)"
grep -q "TODO" docs/ARCHITECTURE.md && fail "docs/ARCHITECTURE.md còn TODO" || pass "ARCHITECTURE.md hoàn thiện"
n=$(find docs/adr -name "0*.md" ! -name "0000-template.md" | wc -l); [ "$n" -ge 3 ] && pass "$n ADR" || fail "cần ≥ 3 ADR (hiện $n)"
[ -f docs/POSTMORTEM.md ] && pass "có POSTMORTEM.md (game day)" || fail "thiếu docs/POSTMORTEM.md"
[ -f docs/COST.md ] && pass "có COST.md" || fail "thiếu docs/COST.md"

summary
