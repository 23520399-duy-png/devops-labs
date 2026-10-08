# DevOps Labs – Thực hành DevOps / DevSecOps trên Local & AWS Academy Learner Lab

Bộ **11 bài lab (00 → 10)** tăng dần độ khó, xoay quanh **một ứng dụng duy nhất** (`shopmini`: FastAPI + PostgreSQL + Redis). Đi hết các bài, bạn sẽ có một hệ thống hoàn chỉnh: hạ tầng dựng bằng Terraform, cấu hình bằng Ansible, CI và quét bảo mật trên GitHub Actions, triển khai GitOps lên Kubernetes, có giám sát và cảnh báo, kèm bài diễn tập khôi phục sau thảm họa (DR).

> Mỗi bài lab là một thư mục riêng, có **README.md** (đề bài + hướng dẫn), **code khởi đầu** và **`verify.sh`** để tự chấm theo các *target* đo được.

## Lộ trình

| Lab | Chủ đề | Chạy ở đâu | Thời lượng | Target chính (tóm tắt) |
|---|---|---|---|---|
| [00](lab00-setup/) | Dựng môi trường làm việc DevOps | Local (WSL2) + Learner Lab | 2–3h | `check-env.sh` xanh 100%, đổi credential Learner Lab trong < 1 phút |
| [01](lab01-docker/) | Docker & Compose chuẩn production | Local | 3–4h | Image < 200 MB, non-root, 0 CVE CRITICAL, p95 < 200 ms ở 50 VU |
| [02](lab02-terraform-aws/) | Terraform: VPC + ALB + Auto Scaling | LocalStack → Learner Lab | 5–6h | `terraform plan` sau apply = *No changes*, tự hồi phục khi instance chết < 5 phút |
| [03](lab03-ansible/) | Ansible: cấu hình & hardening cả fleet | Local (container) → EC2 | 4–5h | Chạy lần 2 `changed=0`, điểm hardening đạt, node_exporter chạy |
| [04](lab04-ci-github-actions/) | CI với GitHub Actions | GitHub (+ `act` local) | 3–4h | Pipeline < 6 phút, image có SBOM, tag semver, PR bị chặn khi test fail |
| [05](lab05-kubernetes/) | Kubernetes chuẩn production trên kind | Local | 5–6h | Rolling update 0 lỗi dưới tải, HPA scale 2→6, NetworkPolicy chặn đúng |
| [06](lab06-gitops-argocd/) | GitOps với Argo CD & Argo Rollouts | Local (kind) | 4–5h | Mọi thay đổi chỉ qua Git, drift tự sửa < 3 phút, canary tự rollback |
| [07](lab07-observability/) | Observability: Prometheus, Grafana, Loki, SLO | Local (kind) | 5–6h | Dashboard RED, alert burn-rate bắn trong < 5 phút khi bơm lỗi |
| [08](lab08-devsecops/) | DevSecOps: pipeline bảo mật & policy-as-code | GitHub + kind | 5–6h | Commit lộ secret / CVE / pod root đều bị chặn, image được ký cosign |
| [09](lab09-aws-ecs-fargate/) | Vận hành trên AWS: ECS Fargate + RDS + CloudWatch | Learner Lab | 5–6h | Alarm → SNS, circuit breaker tự rollback, dashboard vận hành |
| [10](lab10-capstone/) | Capstone: nền tảng GitOps trên AWS + DR drill | Learner Lab | 8–12h | Dựng lại toàn bộ từ con số 0 trong < 30 phút (RTO), mất dữ liệu < 1h (RPO) |

Lab 01, 05, 06, 07 chạy **hoàn toàn local**, không tốn credit AWS. Lab 02, 03, 09, 10 chạy trên **AWS Academy Learner Lab**, trong đó lab 02 và 03 có thêm phương án local (LocalStack / container) để luyện trước.

## Cấu trúc repo

```
devops-labs/
├── app/                      # ứng dụng shopmini dùng chung cho mọi lab
│   ├── src/shopmini/main.py  # API + /healthz /readyz /metrics + chaos
│   ├── tests/                # pytest
│   ├── Dockerfile            # bản tham chiếu (lab 01 sẽ yêu cầu bạn tự viết trước)
│   └── Makefile
├── lab00-setup/ … lab10-capstone/
│   ├── README.md             # đề bài, target, hướng dẫn, sự cố cố ý, câu hỏi
│   ├── verify.sh             # tự chấm target
│   └── (code: terraform/, k8s/, ansible/, .github/ …)
└── scripts/lib.sh            # hàm dùng chung cho verify.sh
```

## Cách học hiệu quả với bộ lab này

1. **Đọc phần "Target" trước**: đó là "đề thi" của từng lab. Bạn chỉ hoàn thành lab khi `./verify.sh` báo **PASS**.
2. **Gõ lại, đừng copy-paste**: những đoạn có nhãn **TODO** bắt buộc bạn tự viết. Lời giải nằm trong `<details>` – chỉ mở sau khi đã thử ít nhất 20 phút.
3. **Làm phần "Sự cố cố ý" (break-fix)**: đây là phần giống công việc DevOps thật nhất. Ghi lại *triệu chứng → cách điều tra → nguyên nhân → cách sửa* vào `NOTES.md` của bạn.
4. **Commit mỗi lab lên GitHub của bạn**: thêm ảnh chụp kết quả và ghi chú. Repo này chính là portfolio khi bạn xin việc remote.
5. **Luôn dọn tài nguyên** sau mỗi phiên Learner Lab (mục *Cleanup* ở cuối mỗi lab).

## Lưu ý quan trọng về AWS Academy Learner Lab

| Giới hạn | Ảnh hưởng tới bài lab | Cách xử lý trong bộ lab |
|---|---|---|
| Chỉ dùng **us-east-1** và **us-west-2** | | Mọi lab mặc định `us-east-1` |
| **Không tạo được IAM user/role** (trừ service-linked role) | Không tự tạo role cho EC2/ECS/Lambda, không tạo OIDC provider cho GitHub | Dùng role có sẵn **`LabRole`** và instance profile **`LabInstanceProfile`** (Terraform dùng `data` source) |
| Credential **tạm thời** (có `aws_session_token`), hết hạn khi phiên kết thúc (~4h) | CLI/Terraform đột nhiên báo `ExpiredToken` | Script `lab00-setup/scripts/academy-creds.sh` dán credential mới trong vài giây |
| EC2 chỉ **nano → large**, tối đa **9 instance**, **32 vCPU**/Region | Không dựng được cluster lớn | Kubernetes trên AWS dùng **k3s** với instance t3.medium/large |
| EBS ≤ 100 GB, gp2/gp3 | | Root volume 20–30 GB |
| RDS: không Multi-AZ, không Enhanced Monitoring | | Lab 09 dùng Single-AZ, có giải thích Multi-AZ trên lý thuyết |
| Hết phiên: EC2 bị **stop** nhưng NAT Gateway, ALB, RDS **vẫn tính tiền** | Có thể đốt hết credit | Mỗi lab có `make destroy` / `terraform destroy` + checklist dọn dẹp |
| Credit có giới hạn | | Mỗi lab ghi **chi phí ước tính** |

> Các giới hạn có thể thay đổi theo từng khóa học. Luôn đọc tài liệu *Readme* trong màn hình Learner Lab của bạn. Nếu một dịch vụ bị từ chối (`AccessDenied`), mỗi lab đều có phương án thay thế.

## Tham khảo (các repo GitHub đã dùng làm nguồn cảm hứng)

- [stefanprodan/podinfo](https://github.com/stefanprodan/podinfo) – mẫu ứng dụng cloud-native chuẩn (health, metrics, graceful shutdown)
- [GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo) – mẫu microservices dùng cho K8s/GitOps
- [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps), [argoproj/argo-rollouts](https://github.com/argoproj/argo-rollouts)
- [prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts) (kube-prometheus-stack)
- [kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind), [k3s-io/k3s](https://github.com/k3s-io/k3s)
- [terraform-aws-modules/terraform-aws-vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc), [localstack/localstack](https://github.com/localstack/localstack)
- [dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening)
- [aquasecurity/trivy](https://github.com/aquasecurity/trivy), [gitleaks/gitleaks](https://github.com/gitleaks/gitleaks), [semgrep/semgrep](https://github.com/semgrep/semgrep), [bridgecrewio/checkov](https://github.com/bridgecrewio/checkov), [sigstore/cosign](https://github.com/sigstore/cosign), [kyverno/policies](https://github.com/kyverno/policies), [bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
- [grafana/k6](https://github.com/grafana/k6), [nektos/act](https://github.com/nektos/act)
- [bregman-arie/devops-exercises](https://github.com/bregman-arie/devops-exercises) – kho câu hỏi phỏng vấn để ôn sau mỗi lab

## Giấy phép

Tài liệu học tập cá nhân. Bạn có thể fork, sửa và đưa lên GitHub làm portfolio.
