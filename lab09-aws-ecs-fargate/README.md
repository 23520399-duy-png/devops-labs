# Lab 09 – Vận hành trên AWS: ECS Fargate + RDS + CloudWatch (Learner Lab)

> **Thời lượng:** 5–6 giờ · **Chạy ở:** AWS Academy Learner Lab · **Chi phí ước tính:** ~0,15 USD/giờ (NAT, ALB, 2 task Fargate 0,25 vCPU, RDS db.t3.micro). **Destroy sau mỗi phiên.**
> Lab này gắn trực tiếp với **SOA-C03**: Domain 1 (CloudWatch, EventBridge), 2 (scaling, backup/PITR), 3 (IaC, deployment), 4 (Secrets Manager, KMS), 5 (VPC, SG).

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Toàn bộ hạ tầng bằng Terraform (dùng lại module network của Lab 02), state trên S3, `plan` = No changes | `verify.sh` |
| T2 | ALB → ECS Fargate (≥ 2 task, private subnet) → RDS Postgres (private, mã hóa, backup) chạy được | `/readyz` = ok |
| T3 | **Không có secret trong code/task definition**: mật khẩu DB do RDS quản lý trong Secrets Manager, inject lúc chạy | `verify.sh` |
| T4 | Deploy hỏng health check → **circuit breaker tự rollback**, có thông báo qua EventBridge → SNS | Bài 4 |
| T5 | Bản lỗi "lọt" qua health check (30% lỗi 5xx) → **composite alarm USER-IMPACT** báo email trong ≤ 5 phút | Bài 5 |
| T6 | Thực hành **PITR**: khôi phục DB về thời điểm trước khi "xóa nhầm" dữ liệu | `evidence/pitr.txt` |
| T7 | Tải tăng → Application Auto Scaling tăng số task, tải giảm → giảm lại | Bài 7 |
| T8 | Debug trong container bằng **ECS Exec**, tìm request lỗi bằng **Logs Insights** | Bài 3 |

## Kiến trúc

```
 Internet ─▶ ALB (public subnets, 2 AZ) ─▶ Target group (type ip, /readyz)
                                              │
                         ┌────────────────────┴─────────────────────┐ private subnets
                         │ ECS service "shopmini" (Fargate, 2–6 task)│──▶ NAT ─▶ ECR, Secrets Manager, Logs
                         │  circuit breaker+rollback · ECS Exec      │
                         └────────────────────┬─────────────────────┘
                                              ▼ 5432 (SG→SG)
                                   RDS Postgres 16 (db.t3.micro, encrypted, PITR)
                                   └─ master password ▶ Secrets Manager (RDS-managed)

 CloudWatch: Container Insights · alarms (5xx %, p95, unhealthy, RDS) · composite USER-IMPACT · dashboard
 EventBridge: ECS deployment failed / task stopped bất thường ─▶ SNS (email)
```

## Kiến thức nền

- **Task execution role và task role**: execution role dùng cho *ECS agent* (kéo image, ghi log, đọc secret khi khởi động); task role là quyền của *code ứng dụng*. Learner Lab chỉ có `LabRole` nên dùng cho cả hai. Ở công ty phải tách riêng và cấp quyền tối thiểu.
- **Circuit breaker** theo dõi task mới. Nếu task liên tục fail (không khởi động được, hoặc health check không qua), ECS đánh dấu deployment **FAILED** và quay về task definition cũ.
- **Cảnh báo triệu chứng và cảnh báo nguyên nhân**: `USER-IMPACT` (lỗi hoặc chậm) là cảnh báo cần gọi người. RDS CPU cao là tín hiệu nguyên nhân, nên đưa vào ticket hoặc dashboard.

---

## Bài 1 – Triển khai

```bash
export AWS_PROFILE=academy AWS_REGION=us-east-1
cd lab09-aws-ecs-fargate/terraform
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars   # điền bucket Lab 02, email
terraform init -backend-config=backend.hcl
terraform apply -target=aws_ecr_repository.app
../scripts/push-image.sh lab09
terraform apply                        # RDS mất ~5–8 phút
curl -s "$(terraform output -raw alb_url)/readyz" | jq
```

Vào email, bấm **Confirm subscription** của SNS. **Câu hỏi:** vì sao nếu chưa confirm thì alarm vẫn chuyển sang ALARM nhưng bạn không nhận được gì?

## Bài 2 – Đọc hiểu cấu hình (ghi vào NOTES.md)

1. Mật khẩu DB đi từ đâu tới container? Vẽ luồng: RDS → Secrets Manager → (execution role) → ECS agent → biến môi trường `DB_PASSWORD`. Ai **không** bao giờ nhìn thấy mật khẩu?
2. Vì sao target group dùng `target_type = "ip"`?
3. `deployment_minimum_healthy_percent = 100` và `maximum_percent = 200` có ý nghĩa gì khi deploy 2 task?
4. Tại sao egress của SG task chỉ cần port 443 và 5432?

## Bài 3 – Vận hành hằng ngày

```bash
../scripts/ecs-exec.sh                      # trong container: env | grep DB_ (mật khẩu có trong env của process – nghĩ về rủi ro)
for i in $(seq 1 50); do curl -s -XPOST "$(terraform output -raw alb_url)/orders" \
  -H 'content-type: application/json' -d "{\"customer\":\"c$i\",\"item\":\"x\",\"quantity\":1,\"price\":2}" >/dev/null; done
```

Mở CloudWatch → **Logs Insights**, chạy các truy vấn trong `scripts/logs-insights.md`. **TODO:** viết truy vấn p95 latency theo route. Mở dashboard (`terraform output dashboard_url`) và **Container Insights**.

## Bài 4 – Deploy hỏng → circuit breaker

```bash
terraform apply -var fail_readiness=true       # task mới không bao giờ healthy
aws ecs describe-services --cluster shop-lab09 --services shopmini \
  --query 'services[0].deployments[].{status:status,rollout:rolloutState,td:taskDefinition,running:runningCount}' --output table
aws ecs describe-services --cluster shop-lab09 --services shopmini --query 'services[0].events[:10].message'
```

Trong 5–15 phút bạn sẽ thấy `rolloutState: FAILED`, ECS tự rollback, và nhận email từ EventBridge. Trong suốt quá trình, `curl /readyz` vẫn trả 200 nhờ các task cũ.

**Quan trọng:** sau khi rollback, chạy `terraform plan`. Terraform muốn deploy lại bản hỏng, vì code vẫn đang khai báo `fail_readiness=true`. **Bài học:** circuit breaker chỉ là chốt chặn khẩn cấp; nguồn sự thật (code/Git) cũng phải được sửa. Chạy `terraform apply -var fail_readiness=false`.

## Bài 5 – Bản lỗi "lọt" health check → alarm

```bash
terraform apply -var chaos_error_rate=0.3      # health check vẫn xanh, nhưng 30% request bị 500
BASE_URL=$(terraform output -raw alb_url) VUS=10 DURATION=8m k6 run ../../lab01-docker/loadtest/k6-load.js
```

Ghi timeline vào `NOTES.md`: lúc apply xong → alarm `5xx-rate` ALARM → `USER-IMPACT` ALARM → email tới. **MTTD** = ? Sau đó rollback (`-var chaos_error_rate=0`) và ghi **MTTR**. Viết postmortem ngắn (dùng template trong `lab07-observability/RUNBOOK.md`).

**TODO:** thêm vào `monitoring.tf` alarm dựa trên metric `Shopmini/AppErrorLogs` (từ metric filter log JSON). So sánh: alarm này và alarm 5xx của ALB, cái nào phát hiện sớm hơn? Cái nào bắt được lỗi mà cái kia bỏ sót?

## Bài 6 – PITR: khôi phục sau "xóa nhầm"

```bash
date -u +%Y-%m-%dT%H:%M:%SZ | tee /tmp/before.txt            # mốc thời gian TRƯỚC sự cố
../scripts/ecs-exec.sh   # trong container:
#   python -c "from shopmini.main import engine; from sqlalchemy import text; c=engine.connect(); c.execute(text('DELETE FROM orders')); c.commit(); print('xóa xong')"
sleep 300   # chờ backup log được đẩy lên (~5 phút)
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier shop-lab09-pg \
  --target-db-instance-identifier shop-lab09-pg-restored --restore-time "$(cat /tmp/before.txt)" \
  --db-instance-class db.t3.micro --no-multi-az --no-publicly-accessible \
  --db-subnet-group-name shop-lab09-db --vpc-security-group-ids "$(aws ec2 describe-security-groups --filters Name=group-name,Values=shop-lab09-db --query 'SecurityGroups[0].GroupId' --output text)" \
  | tee ../evidence/pitr.txt
aws rds wait db-instance-available --db-instance-identifier shop-lab09-pg-restored
```

**TODO:** chứng minh dữ liệu đã quay lại (kết nối từ ECS Exec tới endpoint mới và đếm số dòng trong `orders`). Trả lời: muốn app dùng DB mới **mà không đổi code** thì làm thế nào? (Gợi ý: đổi tên instance, hoặc biến `DB_HOST`.) Xong thì **xóa** instance restored, vì nó **không** nằm trong Terraform.

## Bài 7 – Auto scaling

```bash
BASE_URL=$(terraform output -raw alb_url) VUS=80 DURATION=10m k6 run ../../lab05-kubernetes/loadtest/k6-k8s.js
watch -n 15 "aws ecs describe-services --cluster shop-lab09 --services shopmini --query 'services[0].[desiredCount,runningCount]'"
```

Ghi lại policy nào (CPU hay request/target) kích hoạt scale-out, mất bao lâu, và scale-in mất bao lâu sau khi ngừng tải. Vì sao scale-in luôn chậm hơn?

## Bài 8 – Chấm điểm & dọn dẹp

```bash
cd .. && ./verify.sh
cd terraform && terraform destroy
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'   # đảm bảo không còn instance restored
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Triệu chứng / Hướng điều tra |
|---|---|---|
| B1 | Xóa rule egress 443 của SG task, rồi deploy tag mới | Task STOPPED: `ResourceInitializationError: unable to pull secrets or registry auth` → giải thích bằng luồng mạng của **execution role** |
| B2 | `terraform apply -var image_tag=khong-co` | `CannotPullContainerError` → circuit breaker → rollback |
| B3 | Đổi SG DB chỉ cho phép CIDR `10.99.0.0/16` | `/readyz` 503, ALB 5xx 503 (không còn target healthy). Dùng **Reachability Analyzer** từ ENI của task tới ENI của RDS |
| B4 | Giảm `memory` của task xuống 512 nhưng chạy `WORKERS=4` | Task bị OOM (`OutOfMemoryError: Container killed due to memory usage`) → đọc `stoppedReason` |
| B5 | Xóa subscription email trên SNS | Alarm vẫn ALARM nhưng không ai biết → thêm alarm cho chính kênh cảnh báo (`NumberOfNotificationsFailed`) |

## 🚀 Thử thách mở rộng

- Thêm **ElastiCache Redis** (subnet group, SG từ task) và đặt `REDIS_URL`. So sánh p95 trước và sau khi có cache.
- **Blue/green** cho ECS bằng CodeDeploy (hoặc ECS native blue/green) với 2 target group và listener test.
- **CloudWatch Synthetics canary** gọi `/orders` mỗi phút (nếu Learner Lab cho phép).
- Viết **SSM Automation runbook** "restart ECS service" và gắn vào alarm qua EventBridge (tự khắc phục).
- Chuyển đổi Lab này sang **CDK (TypeScript)** và so sánh độ dài code với Terraform.

## ❓ Câu hỏi tự kiểm tra (gắn với SOA-C03)

1. Task ECS ở private subnet cần những endpoint/đường mạng nào để khởi động? Muốn bỏ NAT thì cần các VPC endpoint nào?
2. Metric filter có tính lại cho log cũ không? Muốn đếm lỗi của tuần trước thì dùng gì?
3. Composite alarm giảm nhiễu như thế nào? Cho ví dụ dùng `actions_suppressor`.
4. PITR luôn tạo instance mới. Quy trình đưa app sang instance mới với downtime nhỏ nhất là gì?
5. So sánh ECS Fargate và EKS (đã dùng ở Lab 05–08): khi nào chọn cái nào?

## Tham khảo

- [terraform-aws-modules/terraform-aws-ecs](https://github.com/terraform-aws-modules/terraform-aws-ecs): module ECS chuẩn cộng đồng, so sánh với code tự viết
- [aws-samples/ecs-refarch-cloudformation](https://github.com/aws-samples/ecs-refarch-cloudformation): kiến trúc tham chiếu ECS
- Giáo trình SOA-C03: Phần 2 (alarm, EventBridge), Phần 6 (PITR), Phần 8 (ECS)
