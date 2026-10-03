# Lab 00 – Dựng môi trường làm việc DevOps (WSL2 + AWS Academy Learner Lab)

> **Thời lượng:** 2–3 giờ · **Chạy ở:** Windows + WSL2 (Ubuntu 24.04) và AWS Academy Learner Lab · **Chi phí AWS:** ~0,05 USD

## 🎯 Target (điều kiện hoàn thành)

| # | Target | Cách đo |
|---|---|---|
| T1 | Toàn bộ công cụ trong `check-env.sh` báo **PASS** | `./scripts/check-env.sh` → 0 FAIL |
| T2 | WSL2 được cấp **≥ 10 GB RAM**, **≥ 4 CPU**, có `systemd` | `free -g`, `nproc`, `systemctl is-system-running` |
| T3 | Nạp credential Learner Lab mới trong **< 1 phút** bằng một lệnh | `scripts/academy-creds.sh` |
| T4 | Mở được shell vào EC2 bằng **Session Manager**: không SSH key, không mở port 22 | `evidence/ssm-session.txt` |
| T5 | Repo `devops-labs` đã đưa lên GitHub của bạn, push bằng SSH | `git remote -v` |

Chạy `./verify.sh` để tự chấm.

## Kiến thức nền cần nắm

- **WSL2** là một máy ảo Linux nhẹ chạy trong Windows. Ổ Windows nằm ở `/mnt/c`, nhưng **luôn để code trong `~` (ext4)**: Docker build và `git status` sẽ nhanh hơn 5–10 lần.
- **Credential tạm thời** (STS) gồm 3 phần: access key, secret key và **session token**. Learner Lab chỉ cấp loại này, và nó hết hạn khi phiên lab kết thúc.
- **Session Manager** (SSM): truy cập server qua agent đi ra HTTPS 443, không cần inbound port. Đây là cách làm chuẩn thay cho bastion host (xem Phần 3 giáo trình SOA-C03).

---

## Bài 1 – Cấu hình WSL2

1. Trong PowerShell (Windows), tạo file `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   memory=10GB          # máy 16 GB: chừa 6 GB cho Windows
   processors=6
   swap=4GB
   localhostForwarding=true

   [experimental]
   autoMemoryReclaim=gradual   # trả RAM lại cho Windows khi rảnh
   sparseVhd=true
   ```

2. Bật `systemd` trong Ubuntu (cần cho Docker Engine, kubelet của kind…). Thêm vào `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   [network]
   generateResolvConf=true
   ```

3. Chạy `wsl --shutdown` trong PowerShell, mở lại Ubuntu rồi kiểm tra:

   ```bash
   free -g && nproc && systemctl is-system-running   # "running" hoặc "degraded" là được
   ```

## Bài 2 – Cài bộ công cụ

```bash
mkdir -p ~/work && cd ~/work
git clone <repo-devops-labs-của-bạn> devops-labs && cd devops-labs/lab00-setup
./scripts/install-tools.sh
exec bash -l               # nạp lại PATH (pipx, ~/.local/bin)
./scripts/check-env.sh
```

**Docker:** cách đơn giản nhất là **Docker Desktop** + bật *WSL integration* cho Ubuntu. Nếu muốn nhẹ hơn và hiểu sâu hơn, cài Docker Engine thẳng trong WSL2 (script sẽ in hướng dẫn).

| Nhóm | Công cụ | Dùng ở lab |
|---|---|---|
| Container | docker, compose, trivy, cosign | 01, 04, 08 |
| IaC | terraform, tflint, checkov | 02, 09, 10 |
| Config mgmt | ansible, ansible-lint | 03, 10 |
| Kubernetes | kubectl, kind, helm, kustomize, k9s, argocd, kubectl-argo-rollouts, kubeseal, kyverno | 05–08, 10 |
| CI | act, pre-commit, gitleaks, yamllint, shellcheck | 04, 08 |
| Test tải | k6 | 01, 05, 07 |
| AWS | aws CLI v2, session-manager-plugin | 02, 03, 09, 10 |

## Bài 3 – Shell năng suất (tự làm)

**TODO:** thêm vào `~/.bashrc`:

- alias `k=kubectl`, bật bash completion cho `kubectl`, `helm`, `terraform`, `aws` (completion của `kubectl` phải hoạt động với cả alias `k`);
- `export AWS_PROFILE=academy` và `export AWS_REGION=us-east-1`;
- prompt hiển thị **git branch** hiện tại và **kube context**.

<details><summary>Gợi ý lời giải</summary>

```bash
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
source <(helm completion bash)
complete -C "$(command -v aws_completer)" aws
complete -C "$(command -v terraform)" terraform
export AWS_PROFILE=academy AWS_REGION=us-east-1
__kctx() { kubectl config current-context 2>/dev/null; }
__gbr()  { git branch --show-current 2>/dev/null; }
PS1='\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\] \[\e[33m\]($(__gbr))\[\e[0m\] \[\e[36m\][$(__kctx)]\[\e[0m\]\n\$ '
```
</details>

## Bài 4 – AWS Academy Learner Lab: credential + Session Manager

1. Vào AWS Academy → khóa *Learner Lab* → **Start Lab** (chờ chấm đỏ chuyển xanh) → **AWS Details** → **AWS CLI: Show** → copy cả khối `[default]`.
2. Chạy `./scripts/academy-creds.sh` (script tự đọc clipboard Windows). Kết quả phải hiện ARN dạng `arn:aws:sts::<acc>:assumed-role/voclabs/user…`.
3. **Tạo EC2 không có SSH key, không mở port nào** rồi vào bằng Session Manager:

```bash
export AWS_PROFILE=academy AWS_REGION=us-east-1
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text)
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --group-name lab00-no-inbound --description "no inbound" \
      --vpc-id "$VPC" --query GroupId --output text)            # không thêm inbound rule nào!
IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
      --iam-instance-profile Name=LabInstanceProfile --security-group-ids "$SG" \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lab00},{Key=Lab,Value=00}]' \
      --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-status-ok --instance-ids "$IID"
aws ssm describe-instance-information --filters Key=InstanceIds,Values="$IID" \
      --query 'InstanceInformationList[0].PingStatus'            # chờ tới khi = "Online" (1–3 phút)
aws ssm start-session --target "$IID"
```

4. Trong phiên shell, chạy `whoami; hostname; curl -s http://169.254.169.254/latest/meta-data/instance-id; exit`. Sau đó lưu bằng chứng bằng **Run Command** (không cần vào shell):

```bash
mkdir -p evidence
CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
      --parameters 'commands=["whoami","hostname","cat /etc/os-release | head -2"]' \
      --query Command.CommandId --output text)
sleep 5
aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" \
      --query '{Instance:InstanceId,Status:Status,Output:StandardOutputContent}' | tee evidence/ssm-session.txt
```

> Lệnh `curl` metadata ở bước 4 sẽ trả về **401** vì AL2023 bắt buộc **IMDSv2**. **TODO:** viết lại lệnh để lấy token trước (header `X-aws-ec2-metadata-token`), rồi giải thích vì sao IMDSv2 chống được tấn công SSRF.

5. **Dọn dẹp:** `aws ec2 terminate-instances --instance-ids "$IID"` → chờ terminated → `aws ec2 delete-security-group --group-id "$SG"`.

## Bài 5 – Đưa repo lên GitHub (portfolio)

```bash
ssh-keygen -t ed25519 -C "you@example.com"     # thêm ~/.ssh/id_ed25519.pub vào GitHub → Settings → SSH keys
git config --global user.name "Your Name"; git config --global user.email "you@example.com"
git config --global init.defaultBranch main; git config --global pull.rebase true
cd ~/work/devops-labs && git remote set-url origin git@github.com:<you>/devops-labs.git && git push -u origin main
```

**TODO:** bật **commit signing bằng SSH key** (`gpg.format ssh`, `user.signingkey`) để commit hiện nhãn *Verified* trên GitHub.

---

## 🔥 Sự cố cố ý (break-fix)

Gây từng lỗi, ghi lại **triệu chứng → cách điều tra → nguyên nhân → cách sửa** vào `NOTES.md`.

| # | Cách gây lỗi | Triệu chứng bạn sẽ thấy |
|---|---|---|
| B1 | Bấm **End Lab**, đợi 1 phút, chạy `aws s3 ls` | `ExpiredToken` → nạp lại credential bằng script |
| B2 | `sudo date -s "-10 min"` rồi gọi `aws sts get-caller-identity` | `SignatureDoesNotMatch` / `Signature expired` (đồng hồ WSL lệch sau khi máy sleep – lỗi rất hay gặp) |
| B3 | `sudo gpasswd -d $USER docker`, mở shell mới, `docker ps` | `permission denied ... docker.sock` |
| B4 | Tạo EC2 **không gắn** `LabInstanceProfile` | Không bao giờ thấy trong `describe-instance-information` → nhớ mẹo **A-R-N** (Agent – Role – Network) |
| B5 | Sửa `/etc/resolv.conf` thành `nameserver 10.255.255.1` | `curl` báo `Could not resolve host` → dùng `dig`, `resolvectl` để chứng minh lỗi nằm ở DNS |

## 🚀 Thử thách mở rộng

- Viết `Makefile` ở thư mục gốc với các target `make env-check`, `make aws-login`, `make aws-whoami`.
- Cài **pre-commit** với hook `gitleaks`, `trailing-whitespace`, `check-yaml` cho toàn repo.
- Tạo **dotfiles repo** riêng và script `bootstrap.sh` để dựng lại máy mới trong 15 phút.

## ❓ Câu hỏi tự kiểm tra

1. Vì sao để code trong `/mnt/c/...` làm Docker build chậm hẳn so với `~/...`?
2. Session token khác access key dài hạn ở điểm nào về bảo mật? Ai cấp nó?
3. Session Manager cần những gì để một instance hiện là *Online*? Nếu instance nằm ở private subnet không có NAT thì sao?
4. IMDSv2 khác IMDSv1 thế nào? Vì sao nó chống được SSRF?
