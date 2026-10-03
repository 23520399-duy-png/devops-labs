#!/usr/bin/env bash
# Lab 02 – tự chấm.  CHAOS=1 ./verify.sh để chạy thêm bài kiểm tra tự hồi phục (~5 phút)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd terraform aws curl jq
DEV=envs/dev

section "Chất lượng code"
check "terraform fmt -check -recursive" terraform fmt -check -recursive .
(cd "$DEV" && terraform validate >/dev/null 2>&1) && pass "terraform validate (envs/dev)" || fail "terraform validate lỗi"
if command -v tflint >/dev/null; then
  (cd "$DEV" && tflint --init >/dev/null 2>&1; tflint --recursive >/dev/null 2>&1) && pass "tflint không lỗi" || fail "tflint báo lỗi"
fi
if command -v checkov >/dev/null; then
  n=$(checkov -d modules --quiet --compact -o json 2>/dev/null | jq '[.. | objects | select(has("failed")) | .failed] | add // 0' 2>/dev/null || echo "?")
  warn "checkov: $n check FAILED trong modules/ (đọc, sửa hoặc ghi lý do chấp nhận vào NOTES.md)"
fi

section "State & drift"
bucket=$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$DEV/backend.hcl" 2>/dev/null)
if [ -n "$bucket" ]; then
  [ "$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null)" = "Enabled" ] \
    && pass "state bucket $bucket bật versioning" || fail "state bucket chưa bật versioning"
  aws s3api head-object --bucket "$bucket" --key lab02/dev/terraform.tfstate >/dev/null 2>&1 \
    && pass "state nằm trên S3 (remote backend)" || fail "không thấy state trên S3"
else fail "chưa có envs/dev/backend.hcl"; fi
(cd "$DEV" && terraform plan -detailed-exitcode -input=false -lock-timeout=60s >/tmp/lab02-plan.txt 2>&1); rc=$?
case $rc in 0) pass "terraform plan: No changes (không drift)";; 2) fail "plan còn thay đổi/drift – xem /tmp/lab02-plan.txt";; *) fail "plan lỗi – xem /tmp/lab02-plan.txt";; esac

section "Hạ tầng chạy thật"
url=$(cd "$DEV" && terraform output -raw alb_url 2>/dev/null)
asg=$(cd "$DEV" && terraform output -raw asg_name 2>/dev/null)
if retry 12 10 curl -fsS --max-time 5 "$url/readyz"; then pass "ALB $url/readyz = 200"; else fail "ALB chưa phục vụ /readyz"; fi
ver=$(curl -s -D - -o /dev/null "$url/" | awk -F': ' 'tolower($1)=="x-app-version"{print $2}' | tr -d '\r')
[ -n "$ver" ] && pass "app version qua ALB: $ver" || warn "không đọc được header x-app-version"
inservice=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
  --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`])' --output text)
[ "${inservice:-0}" -ge 2 ] && pass "ASG có $inservice instance InService/Healthy" || fail "ASG chỉ có ${inservice:-0} instance healthy"
azs=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
  --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l)
[ "$azs" -ge 2 ] && pass "instance trải trên $azs AZ" || fail "instance chỉ nằm trên $azs AZ"
ids=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
pub=$(aws ec2 describe-instances --instance-ids $ids --query 'Reservations[].Instances[].PublicIpAddress' --output text 2>/dev/null)
[ -z "$pub" ] || [ "$pub" = "None" ] && pass "instance app KHÔNG có public IP" || fail "instance app có public IP: $pub"
tokens=$(aws ec2 describe-instances --instance-ids $ids --query 'Reservations[].Instances[].MetadataOptions.HttpTokens' --output text | tr '\t' '\n' | sort -u)
[ "$tokens" = "required" ] && pass "IMDSv2 bắt buộc trên mọi instance" || fail "còn instance cho phép IMDSv1"
appsg=$(cd "$DEV" && terraform output -raw app_sg_id)
open=$(aws ec2 describe-security-groups --group-ids "$appsg" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text)
[ -z "$open" ] && pass "SG app không mở cho dải IP nào (chỉ tham chiếu SG của ALB)" || fail "SG app mở cho CIDR: $open"
aws ssm describe-instance-information --query 'InstanceInformationList[].InstanceId' --output text | grep -q "$(echo $ids | awk '{print $1}')" \
  && pass "instance được SSM quản lý (Session Manager dùng được)" || warn "instance chưa Online trong SSM"

section "Tự hồi phục (CHAOS=1)"
if [ "${CHAOS:-0}" = "1" ]; then
  if ./scripts/chaos-kill-instance.sh && [ "$(cat /tmp/lab02-recovery-seconds)" -le 300 ]; then pass "ASG hồi phục trong $(cat /tmp/lab02-recovery-seconds)s (≤ 300s)"
  else fail "ASG hồi phục quá 5 phút"; fi
else warn "bỏ qua – chạy CHAOS=1 ./verify.sh để kiểm tra target tự hồi phục"; fi

summary
