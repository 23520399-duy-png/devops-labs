# Lab 10 – Capstone: nền tảng GitOps trên AWS + diễn tập thảm họa (DR)

> **Thời lượng:** 8–12 giờ (chia nhiều phiên Learner Lab) · **Chạy ở:** AWS Academy Learner Lab · **Chi phí ước tính:** ~0,14 USD/giờ (3×t3.medium + EIP, **không NAT**) · **Yêu cầu:** đã làm Lab 02–08

Đây là bài tổng hợp, ghép mọi thứ bạn đã làm thành **một hệ thống hoàn chỉnh**, và là project chính để đưa vào CV:

> *"Built a GitOps platform on AWS (Terraform, k3s, Argo CD) with a signed-image supply chain, SLO-based alerting and a tested disaster-recovery runbook: full rebuild in N minutes, RPO ≤ 15 minutes."*

## 🎯 Target (Definition of Done)

| # | Target | Cách đo |
|---|---|---|
| C1 | Hạ tầng chia **2 stack Terraform**: `persistent` (S3 backup, EIP, token SSM: sống sót qua thảm họa) và `cluster` (k3s 1 server + ASG agent: có thể dựng lại bất cứ lúc nào). `plan` = No changes | `verify.sh` |
| C2 | **Không SSH**, không mở port 22: quản trị qua SSM. API 6443 chỉ mở cho IP của bạn. IMDSv2 bắt buộc | review + `verify.sh` |
| C3 | Toàn bộ nền tảng (ingress, sealed-secrets, monitoring, **Kyverno + policy Lab 08**, app) do **Argo CD** cài từ Git; ≥ 5 Application Synced/Healthy | `verify.sh` |
| C4 | Luồng **code → prod** hoàn toàn tự động qua CI (Lab 04), security gate (Lab 08), ký image, GitOps | demo |
| C5 | SLO + alert burn-rate + dashboard hoạt động trên cluster AWS | `verify.sh` |
| C6 | Backup DB → S3 **mỗi 15 phút**; key Sealed Secrets được backup | `verify.sh` |
| C7 | **DR drill**: xóa cluster → dựng lại → khôi phục dữ liệu với **RTO ≤ 30 phút, RPO ≤ 1 giờ** (đo thật) | `evidence/dr-drill-*.log` |
| C8 | **Game day**: ≥ 3 sự cố (bảng bên dưới) được phát hiện bằng alert và xử lý theo runbook, có postmortem | `docs/POSTMORTEM.md` |
| C9 | Tài liệu tiếng Anh: `ARCHITECTURE.md`, **≥ 3 ADR**, `COST.md` | `verify.sh` |

## Kiến trúc

```
                         ┌──────────────── GitHub ────────────────────────────────────────┐
  git push ─────────────▶│ ci.yml → security.yml (gate + cosign sign) → GHCR              │
                         │ cd-bump → commit tag vào lab10-capstone/gitops/envs/aws        │
                         └───────────────────────────┬────────────────────────────────────┘
                                                     │ pull (Argo CD)
  ┌─────────────── AWS Learner Lab (us-east-1) ──────▼──────────────────────────────────────┐
  │ Stack PERSISTENT: S3 backup (versioned) · Elastic IP · SSM SecureString (k3s token)      │
  │ Stack CLUSTER (VPC 10.50/16, public subnets, không NAT):                                 │
  │   EC2 k3s-server (EIP) ── ASG k3s-agents ×2 (tự join bằng token trong SSM)               │
  │   └─ Argo CD ─▶ ingress-nginx · sealed-secrets · kube-prometheus-stack · kyverno         │
  │                 shop-prod: shopmini (HPA) · postgres (local-path PVC) · CronJob pg-backup ─┼─▶ S3
  └──────────────────────────────────────────────────────────────────────────────────────────┘
        người dùng ──▶ http://shop.<EIP>.nip.io        quản trị ──▶ SSM / kubectl :6443 (IP của bạn)
```

---

## Phần A – Dựng lần đầu

```bash
export AWS_PROFILE=academy AWS_REGION=us-east-1
cd lab10-capstone/terraform/persistent
cp backend.hcl.example backend.hcl && terraform init -backend-config=backend.hcl && terraform apply
cd ../cluster
cp backend.hcl.example backend.hcl && terraform init -backend-config=backend.hcl
terraform apply -var my_ip="$(curl -s https://checkip.amazonaws.com)/32" \
  -var eip_allocation_id="$(terraform -chdir=../persistent output -raw eip_allocation_id)" \
  -var eip_public_ip="$(terraform -chdir=../persistent output -raw eip_public_ip)"
cd ../..
./scripts/fill-placeholders.sh            # điền EIP + bucket vào manifest
../lab06-gitops-argocd/scripts/set-repo.sh <github-user>
git add -A && git commit -m "capstone: placeholders" && git push
./scripts/bootstrap.sh                    # kubeconfig qua SSM → Argo CD → root app
```

Lần đầu, app sẽ **chưa Healthy** vì chưa có secret DB (SealedSecret phải được mã hóa bằng key của **chính** cluster này):

```bash
export KUBECONFIG=~/.kube/capstone.yaml
./scripts/seal-db-secret.sh && git add -A && git commit -m "capstone: sealed db" && git push
./scripts/backup-sealed-key.sh            # ⚠️ BẮT BUỘC – thiếu bước này thì DR sẽ thất bại
```

## Phần B – Hoàn thiện nền tảng (bạn tự làm – đây là "đề bài" chính)

| # | Nhiệm vụ | Gợi ý |
|---|---|---|
| B1 | Thêm Application **Kyverno** + thư mục policy của Lab 08 vào `gitops/apps/` (sync-wave trước app) | Policy verify-image cần subject đúng workflow của bạn |
| B2 | Mở rộng `cd-bump.yml` để cập nhật **cả** `lab10-capstone/gitops/envs/aws` (hoặc tạo `promote` riêng cho môi trường này) | Lab 06 |
| B3 | Đưa **dashboard** `lab07-observability/dashboards/shopmini-red.json` vào cluster qua GitOps (ConfigMap có nhãn `grafana_dashboard`) | `configMapGenerator` + `options.labels` |
| B4 | Chuyển mật khẩu admin Grafana sang **SealedSecret** (`grafana.admin.existingSecret`) | Xóa giá trị plaintext khỏi `platform.yaml` |
| B5 | Thêm alert **"backup quá hạn"**: không có Job `pg-backup` thành công trong 1 giờ | `kube_cronjob_status_last_successful_time` (kube-state-metrics) |
| B6 | Alertmanager gửi cảnh báo tới **email/Slack/Discord** thật | Receiver webhook / email |
| B7 | Viết `docs/COST.md`: chi phí theo giờ từng thành phần, so sánh với phương án EKS + NAT + ALB | AWS Pricing Calculator |

## Phần C – Game day (sự cố có kịch bản)

Nhờ một người bạn gây sự cố mà **không báo trước**. Nếu làm một mình thì chạy ngẫu nhiên bằng `shuf`. Bạn chỉ được dùng **alert + dashboard + runbook** để phát hiện và xử lý, đồng thời ghi timeline.

| # | Sự cố | Cách gây | Kỳ vọng |
|---|---|---|---|
| G1 | Node agent chết | `aws ec2 terminate-instances` một agent | ASG tạo node mới, tự join, pod được xếp lại; app không gián đoạn (PDB, nhiều replica) |
| G2 | Bản phát hành lỗi | Merge commit thêm `CHAOS_ERROR_RATE=0.3` (Lab 07) | Alert burn-rate bắn → rollback bằng `git revert` |
| G3 | Ai đó sửa tay production | `kubectl -n shop-prod scale deploy/shopmini --replicas=0` | Argo CD self-heal trong ≤ 3 phút |
| G4 | Image không ký | Đổi tag sang `1.0.0` (chưa ký) | Kyverno chặn, Argo CD báo Degraded, app cũ vẫn chạy |
| G5 | Backup hỏng | Đổi `BACKUP_BUCKET` sai | Alert "backup quá hạn" (B5) bắn sau 1 giờ |
| G6 | Đĩa Postgres đầy | Tạo file lớn trong PVC (`kubectl exec` + `fallocate`) | Bạn phát hiện bằng metric nào? Bổ sung alert |

Ghi postmortem vào `docs/POSTMORTEM.md` (template ở `lab07-observability/RUNBOOK.md`).

## Phần D – DR drill (đỉnh điểm của capstone)

```bash
# Tạo dữ liệu, chờ ít nhất 1 lần backup (≤ 15 phút)
for i in $(seq 1 30); do curl -s -XPOST "http://shop.<EIP>.nip.io/orders" -H 'content-type: application/json' \
  -d "{\"customer\":\"dr$i\",\"item\":\"x\",\"quantity\":1,\"price\":1}" >/dev/null; done
aws s3 ls s3://<bucket>/db/

./scripts/dr-drill.sh        # destroy cluster → apply → bootstrap → restore DB → đo RTO/RPO
```

Mục tiêu: **RTO ≤ 30 phút, RPO ≤ 1 giờ** (thực tế thường ~15–20 phút và ≤ 15 phút). Nếu drill thất bại, đó chính là bài học: ghi lại bước nào gãy (thường gặp: quên backup sealed key, CRD chưa có khi app sync, image chưa ký…), sửa, rồi chạy lại cho tới khi đạt.

**TODO:** viết `docs/adr/0002-…` (chiến lược backup: logical dump vs Velero vs EBS snapshot) và `0003-…` (vì sao tách stack persistent/cluster).

## Phần E – Chấm điểm & trình bày

```bash
./verify.sh
```

Chuẩn bị **demo 10 phút bằng tiếng Anh** (quay video đưa vào README GitHub): kiến trúc → một thay đổi code đi tới production → gây sự cố → alert → rollback → DR drill (tua nhanh) → số liệu RTO/RPO → bài học.

## 🧹 Cleanup

```bash
terraform -chdir=terraform/cluster destroy -var my_ip=0.0.0.0/32 -var eip_allocation_id=x -var eip_public_ip=x
terraform -chdir=terraform/persistent destroy        # chỉ khi đã xong hẳn (mất backup!)
```

> Hết phiên Learner Lab thì EC2 bị stop. Khi bắt đầu phiên mới, k3s tự chạy lại, nhưng IP public của agent đổi (server vẫn giữ EIP). Hãy kiểm tra `kubectl get nodes`, và nếu node lỗi thì chính là cơ hội để luyện G1.

## ❓ Câu hỏi phỏng vấn tổng hợp (trả lời bằng tiếng Anh)

1. Walk me through what happens from `git push` to the change running in production in your project.
2. How do you handle secrets end-to-end (Git, CI, cluster, backups)? What would you change for a real company?
3. Your cluster is gone. Explain your recovery procedure and the RTO/RPO you measured. What dominated the RTO?
4. Why did you choose k3s over EKS? What would change at 10× scale?
5. How do you know your service is healthy? Explain your SLOs and the multi-window burn-rate alert.
6. What are the weakest points of your platform today, and how would you fix them?

## Tham khảo

- [k3s-io/k3s](https://github.com/k3s-io/k3s), [argoproj/argo-cd](https://github.com/argoproj/argo-cd) (App of Apps), [bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) (*Backup and restore keys*)
- [kyverno/kyverno](https://github.com/kyverno/kyverno), [prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts)
- [joelparkerhenderson/architecture-decision-record](https://github.com/joelparkerhenderson/architecture-decision-record): mẫu ADR
- AWS Well-Architected – Reliability Pillar (DR strategies), Google SRE Book – *Postmortem Culture*
