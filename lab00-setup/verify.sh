#!/usr/bin/env bash
# Lab 00 – tự chấm: môi trường + kết quả bài tập Learner Lab.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

"$ROOT/lab00-setup/scripts/check-env.sh" || true   # in chi tiết, không dừng
# Đọc lại kết quả tổng của check-env (chạy lặng để lấy exit code)
section "Tổng hợp môi trường"
if "$ROOT/lab00-setup/scripts/check-env.sh" >/dev/null 2>&1; then pass "check-env.sh không còn FAIL"; else fail "check-env.sh còn FAIL"; fi

section "Bài tập Learner Lab"
if [ -f "$ROOT/lab00-setup/evidence/ssm-session.txt" ] && grep -q "voclabs\|ssm-user\|i-" "$ROOT/lab00-setup/evidence/ssm-session.txt"; then
  pass "có bằng chứng phiên Session Manager (evidence/ssm-session.txt)"
else fail "thiếu evidence/ssm-session.txt (Bài 4)"; fi
if alias k >/dev/null 2>&1 || grep -q "alias k=kubectl" "$HOME/.bashrc" 2>/dev/null; then pass "đã cấu hình alias/completion trong ~/.bashrc"
else warn "chưa thêm alias k=kubectl và completion (Bài 3)"; fi

section "Portfolio"
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then pass "repo đã có remote origin (GitHub)"; else fail "repo chưa push lên GitHub (Bài 5)"; fi

summary
