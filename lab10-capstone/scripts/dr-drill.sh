#!/usr/bin/env bash
# DIỄN TẬP THẢM HỌA: xóa TOÀN BỘ cluster rồi dựng lại từ Git + backup. Đo RTO và RPO thật.
# Yêu cầu: đã chạy backup-sealed-key.sh và có ít nhất 1 bản DB dump trên S3.
set -euo pipefail
source "$(dirname "$0")/common.sh"
MYIP="$(curl -s https://checkip.amazonaws.com)/32"
BUCKET=$(tf_out persistent backup_bucket); EIP=$(tf_out persistent eip_public_ip)
LOG="$CAP_DIR/evidence/dr-drill-$(date +%Y%m%d-%H%M).log"; mkdir -p "$CAP_DIR/evidence"
say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

LAST_ORDER=$(curl -fsS "http://shop.$EIP.nip.io/orders?limit=1" | jq -r '.items[0].created_at // empty')
LAST_BACKUP=$(aws s3 ls "s3://$BUCKET/db/" | sort | tail -1 | awk '{print $1" "$2}')
say "Đơn hàng mới nhất trước thảm họa: $LAST_ORDER · backup mới nhất: $LAST_BACKUP"

say "💥 THẢM HỌA: terraform destroy stack cluster"
terraform -chdir="$CAP_DIR/terraform/cluster" destroy -auto-approve -var my_ip="$MYIP" \
  -var eip_allocation_id="$(tf_out persistent eip_allocation_id)" -var eip_public_ip="$EIP" >>"$LOG" 2>&1
say "Cluster đã mất. BẮT ĐẦU ĐO RTO"
T1=$(date +%s)
terraform -chdir="$CAP_DIR/terraform/cluster" apply -auto-approve -var my_ip="$MYIP" \
  -var eip_allocation_id="$(tf_out persistent eip_allocation_id)" -var eip_public_ip="$EIP" >>"$LOG" 2>&1
say "Hạ tầng xong sau $(( $(date +%s) - T1 ))s"
"$CAP_DIR/scripts/bootstrap.sh" >>"$LOG" 2>&1
say "GitOps đồng bộ xong sau $(( $(date +%s) - T1 ))s"
kubectl -n shop-prod wait --for=condition=Ready pod -l app.kubernetes.io/name=postgres --timeout=300s >>"$LOG" 2>&1
kubectl -n shop-prod create -f "$CAP_DIR/gitops/restore-job.yaml" >>"$LOG" 2>&1
sleep 5; kubectl -n shop-prod wait --for=condition=complete job -l app.kubernetes.io/name=pg-restore --timeout=300s >>"$LOG" 2>&1 || true
until curl -fsS "http://shop.$EIP.nip.io/readyz" >/dev/null 2>&1; do sleep 5; done
T2=$(date +%s)
RESTORED=$(curl -fsS "http://shop.$EIP.nip.io/orders?limit=1" | jq -r '.items[0].created_at // empty')
RTO=$(( T2 - T1 ))
RPO=$(( $(date -d "$LAST_ORDER" +%s 2>/dev/null || echo 0) - $(date -d "$RESTORED" +%s 2>/dev/null || echo 0) ))
say "✅ Dịch vụ phục hồi. RTO = ${RTO}s · đơn mới nhất sau khôi phục: $RESTORED · RPO ≈ ${RPO}s"
echo "RTO_SECONDS=$RTO" >> "$LOG"; echo "RPO_SECONDS=$RPO" >> "$LOG"
