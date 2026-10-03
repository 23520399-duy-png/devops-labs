#!/usr/bin/env bash
# Giả lập sự cố: terminate ngẫu nhiên 1 instance trong ASG rồi đo thời gian ASG tự hồi phục.
set -euo pipefail
cd "$(dirname "$0")/../envs/dev" || exit 1
ASG="$(terraform output -raw asg_name)"
TG_ARN="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
          --query 'AutoScalingGroups[0].TargetGroupARNs[0]' --output text)"
VICTIM="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
          --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' --output text | tr '\t' '\n' | shuf -n1)"
echo "💥 Terminate $VICTIM (không giảm desired capacity)"
aws ec2 terminate-instances --instance-ids "$VICTIM" >/dev/null
START=$(date +%s)
sleep 30
while true; do
  healthy=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
            --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  el=$(( $(date +%s) - START ))
  printf '\r⏱  %3ss – healthy targets: %s ' "$el" "$healthy"
  if [ "$healthy" -ge 2 ] && ! aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
       --query 'TargetHealthDescriptions[].Target.Id' --output text | grep -q "$VICTIM"; then
    echo; echo "✅ Hồi phục sau ${el}s"; echo "$el" > /tmp/lab02-recovery-seconds; break
  fi
  [ "$el" -gt 600 ] && { echo; echo "❌ Quá 10 phút chưa hồi phục"; exit 1; }
  sleep 10
done
