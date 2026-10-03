#!/usr/bin/env bash
# Lab 09 – tự chấm (Learner Lab còn phiên, AWS_PROFILE=academy)
cd "$(dirname "$0")/terraform" || exit 1
ROOT="$(cd ../.. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd terraform aws jq curl
R=${AWS_REGION:-us-east-1}

section "IaC"
check "terraform fmt" terraform fmt -check -recursive
terraform plan -detailed-exitcode -input=false >/tmp/lab09-plan.txt 2>&1; rc=$?
[ $rc -eq 0 ] && pass "plan: No changes" || fail "plan còn thay đổi/lỗi (rc=$rc) – /tmp/lab09-plan.txt"
C=$(terraform output -raw cluster); S=$(terraform output -raw service); URL=$(terraform output -raw alb_url)
DB=$(terraform output -raw db_identifier); LG=$(terraform output -raw log_group)

section "Ứng dụng"
r=$(curl -fsS --max-time 5 "$URL/readyz" 2>/dev/null)
echo "$r" | jq -e '.checks.database=="ok"' >/dev/null 2>&1 && pass "ALB → ECS → RDS: /readyz database ok" || fail "/readyz lỗi: $r"
svc=$(aws ecs describe-services --cluster "$C" --services "$S" --output json | jq '.services[0]')
run=$(echo "$svc" | jq .runningCount); des=$(echo "$svc" | jq .desiredCount)
[ "$run" -ge 2 ] && [ "$run" = "$des" ] && pass "ECS: $run/$des task running" || fail "ECS: $run/$des task running"
echo "$svc" | jq -e '.deploymentConfiguration.deploymentCircuitBreaker.rollback==true' >/dev/null && pass "circuit breaker + rollback bật" || fail "chưa bật circuit breaker rollback"
echo "$svc" | jq -e '.enableExecuteCommand==true' >/dev/null && pass "ECS Exec bật" || fail "ECS Exec tắt"
echo "$svc" | jq -r '.events[].message' | grep -qiE 'rolling back|rolled back|circuit breaker' \
  && pass "có bằng chứng circuit breaker đã rollback một deploy hỏng (Bài 4)" || fail "chưa thấy rollback trong service events (Bài 4)"
td=$(aws ecs describe-task-definition --task-definition "$(echo "$svc" | jq -r .taskDefinition)" --output json | jq '.taskDefinition.containerDefinitions[0]')
echo "$td" | jq -e '[.environment[].name] | map(select(test("PASSWORD|SECRET"))) | length == 0' >/dev/null && pass "không có secret plaintext trong environment" || fail "có secret trong environment"
echo "$td" | jq -e '.secrets | length >= 2' >/dev/null && pass "secret lấy từ Secrets Manager" || fail "chưa dùng secrets"
echo "$td" | jq -e '.readonlyRootFilesystem==true' >/dev/null && pass "readonlyRootFilesystem" || fail "rootfs ghi được"
ci=$(aws ecs describe-clusters --clusters "$C" --include SETTINGS --query 'clusters[0].settings[?name==`containerInsights`].value' --output text)
[ "$ci" = "enabled" ] || [ "$ci" = "enhanced" ] && pass "Container Insights: $ci" || fail "Container Insights tắt"

section "Dữ liệu"
db=$(aws rds describe-db-instances --db-instance-identifier "$DB" --output json | jq '.DBInstances[0]')
echo "$db" | jq -e '.PubliclyAccessible==false' >/dev/null && pass "RDS không public" || fail "RDS public"
echo "$db" | jq -e '.StorageEncrypted==true' >/dev/null && pass "RDS mã hóa at rest" || fail "RDS chưa mã hóa"
echo "$db" | jq -e '.BackupRetentionPeriod>=1' >/dev/null && pass "RDS bật automated backup (PITR)" || fail "RDS tắt backup"
[ -f "$ROOT/lab09-aws-ecs-fargate/evidence/pitr.txt" ] && pass "có bằng chứng thực hành PITR (Bài 6)" || warn "chưa có evidence/pitr.txt (Bài 6)"

section "Giám sát"
n=$(aws cloudwatch describe-alarms --alarm-name-prefix "shop-lab09" --query 'length(MetricAlarms[?length(AlarmActions)>`0`])' --output text)
[ "$n" -ge 5 ] && pass "$n metric alarm có action SNS" || fail "chỉ $n alarm có action"
aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-name-prefix shop-lab09 --query 'CompositeAlarms[0].AlarmName' --output text | grep -q USER-IMPACT \
  && pass "có composite alarm USER-IMPACT" || fail "thiếu composite alarm"
h=$(aws cloudwatch describe-alarm-history --alarm-name shop-lab09-USER-IMPACT --history-item-type StateUpdate --max-items 20 --output json | jq '[.AlarmHistoryItems[] | select(.HistorySummary|test("to ALARM"))] | length')
[ "${h:-0}" -ge 1 ] && pass "USER-IMPACT đã từng chuyển ALARM (Bài 5 – sự cố giả lập)" || fail "USER-IMPACT chưa từng ALARM (Bài 5)"
ret=$(aws logs describe-log-groups --log-group-name-prefix "$LG" --query 'logGroups[0].retentionInDays' --output text)
[ "$ret" != "None" ] && pass "log group có retention ($ret ngày)" || fail "log group không có retention"
aws events list-rules --name-prefix shop-lab09 --query 'length(Rules)' --output text | grep -qE '^[2-9]' && pass "EventBridge rules cho sự kiện ECS" || fail "thiếu EventBridge rules"

summary
