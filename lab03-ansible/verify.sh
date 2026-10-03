#!/usr/bin/env bash
# Lab 03 – tự chấm.
#   ./verify.sh                    → kiểm tra trên container local
#   TARGET=aws ./verify.sh         → kiểm tra fleet EC2 (dynamic inventory)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd ansible-playbook ansible-lint
if [ "${TARGET:-local}" = "aws" ]; then INV=inventories/aws/aws_ec2.yml; else INV=inventories/local/hosts.yml; fi
export ANSIBLE_STDOUT_CALLBACK=ansible.builtin.default

section "Chất lượng code"
if ansible-lint --profile production >/tmp/lab03-lint.txt 2>&1; then pass "ansible-lint (profile production)"; else fail "ansible-lint lỗi – xem /tmp/lab03-lint.txt"; fi
check "syntax-check site.yml" ansible-playbook -i "$INV" site.yml --syntax-check
check "syntax-check rolling-update.yml" ansible-playbook -i "$INV" rolling-update.yml --syntax-check
if command -v gitleaks >/dev/null; then check "không có secret trong lab03 (gitleaks)" gitleaks dir . --no-banner; fi
if grep -rq '\$ANSIBLE_VAULT' group_vars inventories 2>/dev/null; then pass "có biến được mã hóa bằng ansible-vault"; else warn "chưa dùng ansible-vault (Bài 5)"; fi

section "Idempotency"
ansible-playbook -i "$INV" site.yml >/tmp/lab03-run1.txt 2>&1 && pass "lần chạy 1 thành công" || fail "lần chạy 1 lỗi – xem /tmp/lab03-run1.txt"
ansible-playbook -i "$INV" site.yml >/tmp/lab03-run2.txt 2>&1
recap=$(sed -n '/PLAY RECAP/,$p' /tmp/lab03-run2.txt)
sumk() { echo "$recap" | grep -oE "$1=[0-9]+" | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
if [ -n "$recap" ]; then changed=$(sumk changed); failed=$(sumk failed); else changed=99; failed=99; fi
[ "${failed:-99}" = "0" ] && pass "lần chạy 2: failed=0" || fail "lần chạy 2 có lỗi"
[ "${changed:-99}" = "0" ] && pass "lần chạy 2: changed=0 (idempotent)" || fail "lần chạy 2 vẫn changed=$changed → task nào không idempotent? xem /tmp/lab03-run2.txt"

section "Trạng thái máy đích"
adhoc() { ansible all -i "$INV" -b -o -m ansible.builtin.shell -a "$1" 2>/dev/null; }
out=$(adhoc "sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|maxauthtries) '")
echo "$out" | grep -q "passwordauthentication yes" && fail "còn host cho phép đăng nhập bằng mật khẩu" || pass "PasswordAuthentication no trên mọi host"
echo "$out" | grep -qE "permitrootlogin (yes|without-password|prohibit-password)" && fail "còn host cho root đăng nhập" || pass "PermitRootLogin no trên mọi host"
adhoc "test -f /etc/sudoers.d/90-deploy && id deploy" | grep -q FAILED && fail "thiếu user deploy/sudoers" || pass "user deploy + sudoers trên mọi host"
adhoc "grep -q 'tcp_syncookies = 1' /etc/sysctl.d/90-hardening.conf" | grep -q FAILED && fail "thiếu file sysctl hardening" || pass "sysctl hardening đã ghi"
adhoc "/usr/local/bin/node_exporter --version" | grep -q FAILED && fail "node_exporter chưa cài ở một số host" || pass "node_exporter đã cài"

if [ "${TARGET:-local}" = "aws" ]; then
  section "Fleet AWS"
  for ip in $(ansible-inventory -i "$INV" --list 2>/dev/null | jq -r '._meta.hostvars[].ansible_host'); do
    curl -fsS --max-time 5 "http://$ip:9100/metrics" | grep -q node_cpu_seconds_total && pass "$ip:9100 node_exporter trả metric" || fail "$ip:9100 không trả metric"
    curl -fsS --max-time 5 "http://$ip:8080/healthz" >/dev/null && pass "$ip:8080 app healthy" || fail "$ip:8080 app không phản hồi"
  done
  adhoc "sysctl -n net.ipv4.tcp_syncookies" | grep -q '| rc=0.*1$\|(stdout) 1' && pass "sysctl đã áp dụng vào kernel" || warn "kiểm tra sysctl thủ công: sysctl net.ipv4.tcp_syncookies"
fi

summary
