# Mẫu lỗ hổng CÓ CHỦ ĐÍCH – chỉ dùng để chứng minh cổng bảo mật hoạt động

Thư mục này được loại trừ khỏi các bước quét trên `main`. Ở Bài 4, bạn sẽ **copy từng mẫu vào vị trí được quét** trên một branch riêng, mở PR và chứng minh PR bị chặn.

| Mẫu | Copy tới | Công cụ phải bắt được |
|---|---|---|
| `app/leaky_config.py` | `app/src/shopmini/leaky_config.py` | gitleaks (secret), semgrep (hard-coded credential) |
| `app/report.py` | `app/src/shopmini/report.py` | semgrep (SQL injection, `subprocess` với `shell=True`) |
| `docker/Dockerfile.bad` | `app/Dockerfile` (ghi đè) | trivy config / hadolint (root user, `latest`, `ADD` URL) |
| `k8s/privileged-patch.yaml` | thêm vào `patches` của `gitops/envs/dev` | kyverno CLI, Pod Security |
| `terraform/open-sg.tf` | `lab02-terraform-aws/modules/web-asg/open-sg.tf` | checkov, trivy config (SSH 0.0.0.0/0, S3 public) |
