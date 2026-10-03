#!/usr/bin/env bash
# Sau "terraform apply" stack cluster: lấy kubeconfig qua SSM, khôi phục key Sealed Secrets (nếu có),
# cài Argo CD và root app. Từ đây mọi thứ do GitOps đảm nhiệm.
set -euo pipefail
source "$(dirname "$0")/common.sh"
SERVER=$(tf_out cluster server_instance_id); EIP=$(tf_out persistent eip_public_ip); BUCKET=$(tf_out persistent backup_bucket)

echo "==> Chờ k3s server sẵn sàng (qua SSM, không SSH)"
for _ in $(seq 1 60); do
  CID=$(aws ssm send-command --instance-ids "$SERVER" --document-name AWS-RunShellScript \
        --parameters 'commands=["sudo cat /etc/rancher/k3s/k3s.yaml"]' --query Command.CommandId --output text 2>/dev/null) || { sleep 10; continue; }
  sleep 4
  OUT=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$SERVER" --query StandardOutputContent --output text 2>/dev/null || true)
  if echo "$OUT" | grep -q "certificate-authority-data"; then break; fi
  sleep 10
done
mkdir -p "$(dirname "$KUBECONFIG")"
echo "$OUT" | sed "s/127.0.0.1/$EIP/" > "$KUBECONFIG"; chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get nodes -o wide

echo "==> Khôi phục key Sealed Secrets (nếu đã backup) – PHẢI làm trước khi controller khởi động"
if aws s3 ls "s3://$BUCKET/sealed-secrets/key.yaml" >/dev/null 2>&1; then
  aws s3 cp "s3://$BUCKET/sealed-secrets/key.yaml" - | kubectl apply -f -
  echo "   ✔ đã khôi phục key cũ → SealedSecret trong Git giải mã được"
else
  echo "   (chưa có backup key – lần dựng đầu tiên)"
fi

echo "==> Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --set configs.params.server\\.insecure=true \
  --set configs.cm.kustomize\\.buildOptions="--load-restrictor LoadRestrictionsNone" \
  --set configs.cm.timeout\\.reconciliation=60s \
  --set dex.enabled=false --set notifications.enabled=false --wait
kubectl apply -f "$CAP_DIR/gitops/root-app.yaml"
echo "==> Chờ ứng dụng Healthy"
for _ in $(seq 1 60); do
  st=$(kubectl -n argocd get application shopmini -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  echo "   shopmini: ${st:-chưa có}"; [ "$st" = "Synced/Healthy" ] && break; sleep 15
done
echo "✅ http://shop.$EIP.nip.io"
