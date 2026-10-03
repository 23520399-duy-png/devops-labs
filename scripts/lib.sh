#!/usr/bin/env bash
# Thư viện dùng chung cho các verify.sh – in kết quả PASS/FAIL và tổng kết.
# Dùng: source "$(git rev-parse --show-toplevel)/scripts/lib.sh"
set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi

section() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
pass()    { PASS_COUNT=$((PASS_COUNT + 1)); printf '  %s[PASS]%s %s\n' "$G" "$N" "$*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; }
warn()    { WARN_COUNT=$((WARN_COUNT + 1)); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }

# check "mô tả" lệnh...   → PASS nếu lệnh trả exit code 0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# need_cmd docker kubectl ...   → dừng sớm nếu thiếu công cụ
need_cmd() {
  local missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { fail "thiếu lệnh: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || { summary; exit 1; }
}

# retry <số lần> <giây chờ> lệnh...
retry() {
  local n="$1" s="$2"; shift 2
  for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep "$s"; done
  return 1
}

# Lấy số thực từ chuỗi và so sánh: lt 0.2 0.5  → true nếu 0.2 < 0.5
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

summary() {
  printf '\n%sKết quả:%s %s%d PASS%s, %s%d FAIL%s, %s%d WARN%s\n' "$B" "$N" "$G" "$PASS_COUNT" "$N" "$R" "$FAIL_COUNT" "$N" "$Y" "$WARN_COUNT" "$N"
  if [ "$FAIL_COUNT" -eq 0 ]; then printf '%s✔ Đạt toàn bộ target của bài lab.%s\n' "$G" "$N"; return 0
  else printf '%s✘ Chưa đạt – xem các dòng FAIL ở trên.%s\n' "$R" "$N"; return 1; fi
}
