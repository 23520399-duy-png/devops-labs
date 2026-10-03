#!/usr/bin/env bash
# Lab 06 – tự chấm.  DRIFT=1 để chạy thêm bài kiểm tra self-heal (~3 phút)
cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
source "$ROOT/scripts/lib.sh"
need_cmd kubectl jq git

section "Nền tảng GitOps"
check "Argo CD server chạy" kubectl -n argocd rollout status deploy/argocd-server --timeout=5s
check "Argo Rollouts controller chạy" kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=5s
check "Sealed Secrets controller chạy" kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=5s
grep -rq YOUR_GITHUB_USER gitops bootstrap && fail "còn placeholder YOUR_GITHUB_USER (chạy scripts/set-repo.sh)" || pass "đã đặt repo URL của bạn"

section "Applications"
for app in root shopmini-dev shopmini-prod; do
  s=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  [ "$s" = "Synced/Healthy" ] && pass "$app: Synced/Healthy" || fail "$app: ${s:-không tồn tại}"
done
auto=$(kubectl -n argocd get application shopmini-dev -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')
[ "$auto" = "true" ] && pass "dev bật automated selfHeal" || fail "dev chưa bật selfHeal"

section "Secret trong Git"
for e in dev prod; do
  f="gitops/envs/$e/sealed-db.yaml"
  if [ -f "$f" ] && grep -q "kind: SealedSecret" "$f"; then pass "$e: secret dạng SealedSecret"; else fail "$e: thiếu sealed-db.yaml"; fi
done
if git -C "$ROOT" log --all -p -- 'lab05-kubernetes/k8s/overlays/*/db.env' 2>/dev/null | grep -q '^+password='; then
  fail "db.env (plaintext) từng bị commit vào Git – xem lại lịch sử!"; else pass "không có db.env plaintext trong lịch sử Git"; fi

section "Luồng CD tự động"
if git -C "$ROOT" log --oneline -20 -- lab06-gitops-argocd/gitops/envs/dev/kustomization.yaml | grep -q "chore(dev): deploy"; then
  pass "có commit tự động của cd-bump (CI ghi vào Git)"; else fail "chưa thấy commit 'chore(dev): deploy' từ workflow cd-bump"; fi
img=$(kubectl -n shop-dev get deploy shopmini -o jsonpath='{.spec.template.spec.containers[0].image}')
want=$(grep -A2 'name: shopmini' gitops/envs/dev/kustomization.yaml | awk '/newName/{n=$2}/newTag/{t=$2} END{gsub(/"/,"",t); print n":"t}')
[ "$img" = "$want" ] && pass "image đang chạy ở dev = Git ($img)" || fail "dev chạy $img nhưng Git khai báo $want"

section "Canary (prod)"
ph=$(kubectl -n shop-prod get rollout shopmini -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ph" = "Healthy" ] && pass "Rollout prod: Healthy" || fail "Rollout prod: ${ph:-không có}"
ar=$(kubectl -n shop-prod get analysisrun -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Failed")] | length')
[ "${ar:-0}" -ge 1 ] && pass "đã có ít nhất 1 AnalysisRun Failed (Bài 5 – canary hỏng tự rollback)" || fail "chưa thử canary hỏng (Bài 5)"

section "Self-heal (DRIFT=1)"
if [ "${DRIFT:-0}" = "1" ]; then
  kubectl -n shop-dev patch configmap shopmini-config --type merge -p '{"data":{"LOG_LEVEL":"DEBUG"}}' >/dev/null
  if retry 18 10 sh -c "[ \"\$(kubectl -n shop-dev get cm shopmini-config -o jsonpath='{.data.LOG_LEVEL}')\" = INFO ]"; then
    pass "Argo CD tự sửa drift trong ≤ 3 phút"; else fail "drift không được sửa sau 3 phút"; fi
else warn "bỏ qua – DRIFT=1 ./verify.sh"; fi

summary
