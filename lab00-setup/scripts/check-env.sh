#!/usr/bin/env bash
# Kiểm tra môi trường làm việc cho bộ DevOps Labs.
# Dùng: ./check-env.sh            (bỏ qua kiểm tra AWS nếu chưa có credential)
#       AWS_CHECK=1 ./check-env.sh (bắt buộc kiểm tra AWS Academy)
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib.sh
source "$ROOT/scripts/lib.sh"

section "1. Hệ điều hành & tài nguyên"
if grep -qi microsoft /proc/version 2>/dev/null; then pass "đang chạy trong WSL2"; else warn "không phải WSL2 (ok nếu dùng Linux/macOS)"; fi
mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
if [ "$mem_gb" -ge 8 ]; then pass "RAM cấp cho Linux: ${mem_gb} GB (≥ 8)"; else fail "RAM cấp cho Linux: ${mem_gb} GB < 8 → sửa %UserProfile%\\.wslconfig"; fi
cpus=$(nproc)
if [ "$cpus" -ge 4 ]; then pass "CPU: $cpus core (≥ 4)"; else warn "CPU: $cpus core – kind nhiều node sẽ chậm"; fi
disk_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
if [ "$disk_gb" -ge 30 ]; then pass "Ổ đĩa trống: ${disk_gb} GB (≥ 30)"; else fail "Ổ đĩa trống: ${disk_gb} GB < 30"; fi

section "2. Công cụ bắt buộc"
for c in git make jq yq curl docker kubectl kind helm kustomize k9s terraform tflint aws session-manager-plugin \
         ansible ansible-lint trivy gitleaks cosign checkov k6 act argocd kubectl-argo-rollouts kubeseal kyverno \
         pre-commit yamllint shellcheck; do
  if command -v "$c" >/dev/null 2>&1; then pass "$c"; else fail "$c chưa cài (chạy scripts/install-tools.sh)"; fi
done

section "3. Docker"
if docker info >/dev/null 2>&1; then pass "Docker daemon chạy, dùng được không cần sudo"
else fail "docker info lỗi – daemon chưa chạy hoặc user chưa thuộc nhóm docker"; fi
if docker run --rm hello-world >/dev/null 2>&1; then pass "docker run hello-world"; else fail "không chạy được container (mạng/registry?)"; fi
if docker compose version >/dev/null 2>&1; then pass "docker compose v2"; else fail "thiếu docker compose v2"; fi

section "4. Git & GitHub"
if [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; then pass "git user.name/email đã cấu hình"
else fail "chưa cấu hình git user.name / user.email"; fi
if ls "$HOME"/.ssh/id_ed25519.pub >/dev/null 2>&1; then pass "có SSH key ed25519"; else fail "chưa có ~/.ssh/id_ed25519 (ssh-keygen -t ed25519)"; fi
if ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 | grep -q "successfully authenticated"; then pass "SSH tới GitHub thành công"
else fail "SSH tới GitHub chưa được (thêm public key vào GitHub → Settings → SSH keys)"; fi

section "5. Đồng hồ hệ thống (lệch giờ → lỗi chữ ký AWS)"
remote=$(curl -fsSI --max-time 5 https://aws.amazon.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
if [ -n "$remote" ]; then
  drift=$(( $(date +%s) - $(date -d "$remote" +%s) )); drift=${drift#-}
  if [ "$drift" -le 60 ]; then pass "lệch giờ ${drift}s (≤ 60s)"; else fail "lệch giờ ${drift}s → chạy: sudo hwclock -s  (hoặc wsl --shutdown)"; fi
else warn "không đo được lệch giờ (không có mạng?)"; fi

section "6. AWS Academy Learner Lab"
if [ "${AWS_CHECK:-0}" = "1" ] || aws configure list-profiles 2>/dev/null | grep -qx academy; then
  if out=$(aws sts get-caller-identity --profile "${AWS_PROFILE:-academy}" --output json 2>&1); then
    arn=$(printf '%s' "$out" | jq -r .Arn)
    pass "credential hợp lệ: $arn"
    if printf '%s' "$arn" | grep -q "voclabs"; then pass "đúng tài khoản Learner Lab (assumed-role voclabs)"; else warn "ARN không chứa 'voclabs' – có phải tài khoản Learner Lab?"; fi
    reg=$(aws configure get region --profile "${AWS_PROFILE:-academy}")
    case "$reg" in us-east-1|us-west-2) pass "region $reg được Learner Lab hỗ trợ";; *) fail "region '$reg' không được hỗ trợ (dùng us-east-1)";; esac
    if aws iam get-instance-profile --instance-profile-name LabInstanceProfile --profile "${AWS_PROFILE:-academy}" >/dev/null 2>&1; then pass "tìm thấy LabInstanceProfile"
    else warn "không đọc được LabInstanceProfile (có thể do quyền IAM bị giới hạn)"; fi
  else
    if printf '%s' "$out" | grep -q ExpiredToken; then fail "credential hết hạn → Start Lab rồi chạy scripts/academy-creds.sh"
    else fail "aws sts lỗi: $(printf '%s' "$out" | tail -1)"; fi
  fi
else
  warn "chưa có profile 'academy' – bỏ qua (chạy scripts/academy-creds.sh khi làm lab AWS)"
fi

summary
