#!/usr/bin/env bash
# Cập nhật credential tạm thời của AWS Academy Learner Lab vào ~/.aws/credentials.
#
# Cách dùng:
#   1. Learner Lab → "AWS Details" → "AWS CLI: Show" → copy toàn bộ khối [default] ...
#   2. Chạy:  ./academy-creds.sh            (tự đọc clipboard Windows qua powershell.exe)
#      hoặc:  ./academy-creds.sh < creds.txt
#      hoặc:  ./academy-creds.sh --paste   (dán vào terminal rồi Ctrl-D)
#   Profile mặc định là "academy" (đổi bằng biến PROFILE=...).
set -euo pipefail
PROFILE="${PROFILE:-academy}"
REGION="${REGION:-us-east-1}"

if [ "${1:-}" = "--paste" ]; then
  echo "Dán khối credential rồi nhấn Ctrl-D:" >&2
  RAW="$(cat)"
elif [ ! -t 0 ]; then
  RAW="$(cat)"
elif command -v powershell.exe >/dev/null 2>&1; then
  RAW="$(powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r')"
else
  echo "Không đọc được clipboard. Dùng: $0 --paste" >&2; exit 1
fi

get() { printf '%s\n' "$RAW" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | head -1 | tr -d '\r'; }
AK="$(get aws_access_key_id)"; SK="$(get aws_secret_access_key)"; ST="$(get aws_session_token)"
if [ -z "$AK" ] || [ -z "$SK" ] || [ -z "$ST" ]; then
  echo "✘ Không tìm thấy đủ aws_access_key_id / aws_secret_access_key / aws_session_token trong nội dung đã dán." >&2
  exit 1
fi

aws configure set aws_access_key_id     "$AK" --profile "$PROFILE"
aws configure set aws_secret_access_key "$SK" --profile "$PROFILE"
aws configure set aws_session_token     "$ST" --profile "$PROFILE"
aws configure set region                "$REGION" --profile "$PROFILE"
aws configure set output                json --profile "$PROFILE"

echo "→ Đã ghi profile [$PROFILE] (region $REGION). Kiểm tra danh tính:"
aws sts get-caller-identity --profile "$PROFILE" --query '{Account:Account,Arn:Arn}' --output table
echo
echo "Gợi ý: export AWS_PROFILE=$PROFILE   (thêm vào ~/.bashrc để Terraform/CLI dùng mặc định)"
