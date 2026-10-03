#!/usr/bin/env bash
# Mở shell trong container đang chạy (ECS Exec qua SSM – không SSH, không mở port)
set -euo pipefail
cd "$(dirname "$0")/../terraform" || exit 1
C=$(terraform output -raw cluster); S=$(terraform output -raw service)
T=$(aws ecs list-tasks --cluster "$C" --service-name "$S" --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster "$C" --task "$T" --container api --interactive --command "/bin/sh"
