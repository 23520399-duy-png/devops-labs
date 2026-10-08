# Lab 02 – Terraform: VPC + ALB + Auto Scaling trên AWS (Learner Lab)

> **Thời lượng:** 5–6 giờ · **Chạy ở:** LocalStack (luyện) → AWS Academy Learner Lab · **Chi phí ước tính:** ~0,13 USD/giờ khi đang chạy (NAT + ALB + 2×t3.small), nhớ **destroy** sau mỗi phiên

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Code qua `terraform fmt`, `validate`, `tflint`; checkov đã được đọc và xử lý | `verify.sh` |
| T2 | State lưu ở **S3 remote backend**, bật versioning, mã hóa, khóa bằng `use_lockfile` | `verify.sh` |
| T3 | Sau `apply`, `terraform plan` = **No changes** (không drift, không "vĩnh viễn thay đổi") | `plan -detailed-exitcode` = 0 |
| T4 | `http://<ALB>/readyz` = 200; ≥ 2 instance healthy trên **2 AZ**; instance **không có public IP**, **IMDSv2**, SG app chỉ nhận traffic từ SG của ALB | `verify.sh` |
| T5 | Terminate 1 instance → ASG **tự hồi phục ≤ 5 phút**, ALB không trả lỗi cho người dùng | `CHAOS=1 ./verify.sh` |
| T6 | Đổi image tag → **instance refresh** thay dần toàn bộ instance, không downtime | k6 chạy song song: lỗi < 1% |
| T7 | Bài refactor: đổi tên resource bằng `moved {}` mà **không destroy** tài nguyên | `plan` chỉ có "moved" |

## Kiến trúc

```
                     Internet
                        │ :80
        ┌───────────────▼────────────────┐  VPC 10.20.0.0/16
        │  ALB (public subnets, 2 AZ)    │
        └──────┬──────────────────┬──────┘
   AZ-a        │                  │        AZ-b
 ┌─────────────▼────┐   ┌─────────▼────────┐
 │ public 10.20.0/24│   │ public 10.20.1/24│ ← NAT GW (1 cái – tiết kiệm)
 ├──────────────────┤   ├──────────────────┤
 │private 10.20.10/24│  │private 10.20.11/24│
 │  EC2 (ASG) :8000 │   │  EC2 (ASG) :8000 │  ← docker run shopmini (pull từ ECR)
 └──────────────────┘   └──────────────────┘
        S3 gateway endpoint · CloudWatch alarms → SNS · SSM Session Manager
```

```
lab02-terraform-aws/
├── bootstrap/           # tạo S3 bucket chứa state (chạy 1 lần)
├── modules/network/     # VPC, subnet, IGW, NAT, route, S3 endpoint, flow logs
├── modules/web-asg/     # SG, ALB, TG, launch template, ASG, scaling, alarms
├── envs/dev/            # "root module" ghép các module + ECR + SNS
├── localstack/          # luyện module network không tốn tiền
└── scripts/             # push-image.sh, chaos-kill-instance.sh
```

## Kiến thức nền

- **Root module và child module**: `envs/dev` là nơi ghép các module lại. Mỗi môi trường (dev/staging/prod) có một thư mục riêng và **state riêng**.
- **State** là "bản đồ" giữa code và tài nguyên thật. Mất state thì Terraform tưởng chưa có gì và sẽ tạo trùng; hai người cùng `apply` một lúc thì state hỏng. Vì vậy cần remote backend và cơ chế khóa.
- **Learner Lab không cho tạo IAM role**, nên code dùng `data "aws_iam_instance_profile" "lab"` để lấy `LabInstanceProfile` có sẵn. Ngoài môi trường học, bạn sẽ tự tạo role + instance profile với quyền tối thiểu.

---

## Bài 1 – Luyện trên LocalStack (không tốn credit)

```bash
cd lab02-terraform-aws/localstack
docker compose up -d
terraform init && terraform apply -auto-approve
aws --endpoint-url http://localhost:4566 ec2 describe-route-tables \
    --query 'RouteTables[].Routes[].[DestinationCidrBlock,NatGatewayId,GatewayId]' --output table
```

**TODO:** đổi `single_nat_gateway` giữa `true` và `false`, chạy `terraform plan` rồi giải thích trong `NOTES.md`: tạo thêm/bớt những resource nào? Đánh đổi giữa **chi phí** và **khả năng chịu lỗi theo AZ** ra sao?

Dọn: `terraform destroy -auto-approve && docker compose down -v`.

## Bài 2 – Remote state

```bash
export AWS_PROFILE=academy AWS_REGION=us-east-1
cd ../bootstrap && terraform init && terraform apply
cd ../envs/dev
cp backend.hcl.example backend.hcl            # điền bucket từ output state_bucket
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
```

**Câu hỏi:** vì sao `backend "s3" {}` để trống và đưa cấu hình ra `backend.hcl`? Vì sao `bootstrap` lại dùng state local?

## Bài 3 – Triển khai từng bước

```bash
# 3.1 Tạo ECR trước để có chỗ push image (cách dùng -target hợp lý: bootstrap phụ thuộc)
terraform apply -target=aws_ecr_repository.app
../../scripts/push-image.sh lab02

# 3.2 Toàn bộ hạ tầng
terraform plan -out tfplan        # ĐỌC kỹ plan: bao nhiêu resource? có gì bị replace?
terraform apply tfplan
curl -s "$(terraform output -raw alb_url)/readyz" | jq
```

> ⚠️ `-target` chỉ nên dùng cho tình huống bootstrap hoặc khẩn cấp như ở đây. Dùng thường xuyên sẽ khiến state lệch khỏi code.

Đọc log khởi động của instance qua Session Manager (không SSH):

```bash
IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$(terraform output -raw asg_name)" \
      --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$IID"
# trong instance: sudo tail -50 /var/log/cloud-init-output.log; sudo docker ps; curl -s localhost:8000/readyz
```

## Bài 4 – Rolling deploy bằng instance refresh

1. Sửa một dòng trong app (ví dụ message ở `/`) rồi push tag mới: `../../scripts/push-image.sh lab02-v2`.
2. Mở terminal khác và chạy tải liên tục: `BASE_URL=$(terraform output -raw alb_url) VUS=10 DURATION=8m k6 run ../../../lab01-docker/loadtest/k6-load.js`
3. Đặt `image_tag = "lab02-v2"` trong `terraform.tfvars`, rồi `terraform apply`. Launch template đổi version, kéo theo **instance refresh**.
4. Theo dõi: `aws autoscaling describe-instance-refreshes --auto-scaling-group-name <asg>` và header `x-app-version` (`watch -n2 "curl -sI <alb>/ | grep -i x-app-version"`).

**Target T6:** k6 báo lỗi < 1% trong suốt quá trình refresh. **TODO:** giải thích `deregistration_delay = 30` và `health_check_grace_period = 180` đóng vai trò gì ở bước này.

## Bài 5 – Tự viết thêm (bắt buộc)

| # | Nhiệm vụ | Kỹ năng |
|---|---|---|
| 5.1 | Thêm **scheduled action**: 20:00 hằng ngày giảm `min/desired` còn 1, 08:00 tăng lại 2 (`aws_autoscaling_schedule`, time zone `Asia/Ho_Chi_Minh`) | Tối ưu chi phí |
| 5.2 | Tạo môi trường `envs/staging` dùng lại module, CIDR `10.30.0.0/16`, state key riêng | Tái sử dụng module |
| 5.3 | Tạo bằng tay (console) một SG tên `manual-sg`, rồi đưa vào Terraform bằng khối `import {}` | Import tài nguyên có sẵn |
| 5.4 | Đổi tên `aws_autoscaling_policy.cpu` thành `aws_autoscaling_policy.cpu_target` bằng khối `moved {}`: `plan` **không** được có destroy | Refactor an toàn (T7) |
| 5.5 | Thêm alarm `HighCPU` > 80% trong 5 phút gửi SNS và nhận email thật (`alert_email`) | Giám sát |

<details><summary>Gợi ý 5.3 và 5.4</summary>

```hcl
import {
  to = aws_security_group.manual
  id = "sg-0123456789abcdef0"
}
# terraform plan -generate-config-out=generated.tf   ← Terraform tự sinh code cho resource được import

moved {
  from = aws_autoscaling_policy.cpu
  to   = aws_autoscaling_policy.cpu_target
}
```
</details>

## Bài 6 – Chấm điểm

```bash
cd lab02-terraform-aws && ./verify.sh          # CHAOS=1 ./verify.sh để kiểm tra T5
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Triệu chứng / Hướng điều tra |
|---|---|---|
| B1 | Trên console, thêm inbound `0.0.0.0/0:22` vào SG app | `terraform plan` phát hiện **drift**. Quyết định: Terraform ghi đè hay cập nhật code? Ghi lý do |
| B2 | Mở 2 terminal, chạy `terraform apply` cùng lúc | Lỗi khóa state (`use_lockfile`). Khi nào mới được dùng `force-unlock`? |
| B3 | Đặt `health_check_path = "/nope"` rồi apply | Target unhealthy, ASG thay instance liên tục ("vòng lặp chết"). Tìm thấy trong **Activity history** của ASG |
| B4 | Xóa route `0.0.0.0/0 → NAT` trong route table private (console) | Instance mới không pull được image, user-data treo → đọc `/var/log/cloud-init-output.log` qua SSM. Nếu SSM cũng mất thì sao? (gợi ý: interface endpoints) |
| B5 | `http_put_response_hop_limit = 1` | Container không lấy được credential từ IMDS (nếu app gọi AWS) → giải thích "hop" |
| B6 | Push image tag mới nhưng **không** đổi `image_tag` | Không có gì thay đổi. Vì sao? Tại sao dùng tag `latest` cho deploy là anti-pattern? |

## 🚀 Thử thách mở rộng

- Bật **ALB access logs** vào S3 (bucket policy cho ELB service principal), rồi dùng Athena tìm top 10 URI chậm nhất.
- Thay `single_nat_gateway` bằng **interface endpoints** (ecr.api, ecr.dkr, ssm, ssmmessages, ec2messages, logs) và tính xem có rẻ hơn NAT không.
- Viết **Terratest** (Go) hoặc `terraform test` (`*.tftest.hcl`) kiểm tra module network sinh đúng số subnet.
- Thêm **pre-commit** với `terraform_fmt`, `terraform_validate`, `terraform_tflint`, `checkov`.

## 🧹 Cleanup (bắt buộc cuối mỗi phiên)

```bash
cd envs/dev && terraform destroy
# muốn giữ state bucket cho lần sau thì KHÔNG destroy bootstrap
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'   # phải rỗng
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'                              # phải rỗng
```

## ❓ Câu hỏi tự kiểm tra

1. `count` và `for_each` khác nhau thế nào? Vì sao xóa phần tử giữa list khi dùng `count` có thể gây destroy dây chuyền?
2. Khi nào dùng `lifecycle { create_before_destroy = true }`? `ignore_changes = [desired_capacity]` giải quyết vấn đề gì?
3. ASG health check `EC2` và `ELB` khác nhau ra sao?
4. Vì sao SG của app tham chiếu **SG của ALB** thay vì CIDR của public subnet?
5. Làm thế nào để Terraform chạy trong CI an toàn (plan ở PR, apply khi merge, ai duyệt)?

## Tham khảo

- [terraform-aws-modules/terraform-aws-vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) và [terraform-aws-modules/terraform-aws-autoscaling](https://github.com/terraform-aws-modules/terraform-aws-autoscaling): đọc code module "chuẩn công nghiệp" và so sánh với module tự viết
- [localstack/localstack](https://github.com/localstack/localstack)
- [terraform-linters/tflint](https://github.com/terraform-linters/tflint), [bridgecrewio/checkov](https://github.com/bridgecrewio/checkov)
