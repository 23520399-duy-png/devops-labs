#!/usr/bin/env bash
# Lab 08 – tự chấm (cần gh, kubectl, cosign)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd gh kubectl jq
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
OWNER=$(echo "${REPO%%/*}" | tr '[:upper:]' '[:lower:]')

section "Cấu hình shift-left trong repo"
for f in .github/workflows/security.yml .gitleaks.toml .trivyignore .checkov.yaml; do check "$f tồn tại" test -f "$ROOT/$f"; done
if [ -f "$ROOT/.trivyignore" ]; then
  bad=$(grep -vE '^\s*(#|$)' "$ROOT/.trivyignore" | grep -vc '#' || true)
  [ "${bad:-0}" = "0" ] && pass ".trivyignore: mọi dòng ignore đều có lý do (comment)" || fail ".trivyignore có $bad dòng ignore không ghi lý do"
fi
command -v gitleaks >/dev/null && { (cd "$ROOT" && gitleaks git --no-banner -c .gitleaks.toml >/dev/null 2>&1) && pass "gitleaks: lịch sử Git sạch" || fail "gitleaks phát hiện secret trong lịch sử"; }

section "Pipeline"
c=$(gh run list -R "$REPO" --workflow security.yml --branch main --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null)
[ "$c" = "success" ] && pass "security.yml trên main: success" || fail "security.yml trên main: ${c:-chưa chạy}"
n=0
for pr in $(gh pr list -R "$REPO" --state all --label lab08-red --json number -q '.[].number' 2>/dev/null); do
  gh pr checks "$pr" -R "$REPO" 2>/dev/null | grep -qiE 'fail' && n=$((n+1))
done
[ "$n" -ge 4 ] && pass "$n PR lab08-red bị cổng bảo mật chặn (≥ 4)" || fail "chỉ $n PR lab08-red bị chặn (cần ≥ 4: secret, SAST, IaC, K8s policy)"

section "Chuỗi cung ứng (supply chain)"
if command -v cosign >/dev/null; then
  IMG=$(kubectl -n shop-dev get deploy shopmini -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if cosign verify "$IMG" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
       --certificate-identity-regexp "^https://github.com/${REPO}/" >/dev/null 2>&1; then pass "image đang chạy ở dev có chữ ký cosign hợp lệ"
  else fail "cosign verify thất bại cho $IMG"; fi
  cosign verify-attestation "$IMG" --type spdxjson --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp "^https://github.com/${REPO}/" >/dev/null 2>&1 && pass "có SBOM attestation" || fail "thiếu SBOM attestation"
else warn "chưa cài cosign"; fi

section "Admission control (Kyverno)"
check "Kyverno chạy" kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=5s
nready=$(kubectl get clusterpolicy -o json 2>/dev/null | jq '[.items[] | select(.status.ready==true or (.status.conditions[]?|select(.type=="Ready").status=="True"))] | length')
[ "${nready:-0}" -ge 5 ] && pass "$nready ClusterPolicy Ready" || fail "chỉ ${nready:-0} ClusterPolicy Ready"
if kubectl -n shop-dev run t1 --image=nginx:latest --dry-run=server >/dev/null 2>&1; then fail "pod nginx:latest KHÔNG bị chặn"; else pass "pod nginx:latest bị chặn"; fi
if kubectl -n shop-dev run t2 --image="ghcr.io/$OWNER/shopmini:1.0.0" --dry-run=server >/dev/null 2>&1; then fail "image chưa ký (1.0.0) KHÔNG bị chặn"; else pass "image chưa ký shopmini:1.0.0 bị chặn"; fi
viol=$(kubectl get policyreport -n shop-dev -o json 2>/dev/null | jq '[.items[].summary.fail] | add // 0')
[ "$viol" = "0" ] && pass "PolicyReport shop-dev: 0 vi phạm" || fail "PolicyReport shop-dev: $viol vi phạm"

summary
