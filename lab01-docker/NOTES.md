# Lab 01 – Ghi chú

## Bài 1 – Vấn đề của Dockerfile.naive

| # | Vấn đề | Bằng chứng | Rủi ro | Cách sửa |
|---|---|---|---|---|
| 1 | Base `python:3.12` (bản full) | `history`: layer gcc/g++/imagemagick 695 MB, git/svn 202 MB; image 1.85 GB | Pull/deploy chậm, nhiều gói thừa → nhiều CVE | `python:3.12-slim` + multi-stage |
| 2 | `COPY . .` trước `pip install` | Sửa README → build lại chạy lại `pip install` | Build chậm, CI tốn thời gian | `COPY requirements.txt` → `pip install` → mới `COPY src` |
| 3 | Đồ nghề dev trong image | `which` thấy gcc, pytest, ruff; layer pytest/ruff 53 MB | Kẻ tấn công có sẵn compiler; image nặng | Build wheel ở stage builder; dev deps chỉ dùng trong CI |
| 4 | Secret trong `ENV` | `docker history` đọc được `SuperSecret123` mà không cần chạy container | Ai pull được image là có mật khẩu DB; không xóa được khỏi layer | Truyền lúc chạy (env_file/.env, Docker secrets, Secrets Manager) |
| 5 | Chạy bằng root | `id` → `uid=0(root)` | Bị khai thác app = có root trong container, dễ leo thang | `useradd -u 10001` + `USER 10001` |
| 6 | `--reload` (chế độ dev) | Log "Started reloader process", thêm process canh file | Tốn tài nguyên; ghi được file là app tự nạp code mới | Bỏ `--reload`, dùng `--workers N` |
| 7 | `CMD` dạng shell form | PID 1 = `/bin/sh -c ...`; `docker stop` mất 11.6s; cảnh báo JSONArgsRecommended | Không graceful shutdown, request bị cắt, rollout chậm | Exec form `CMD ["uvicorn", ...]` hoặc `exec` trong script |
| 8 | Không có `HEALTHCHECK` | `docker ps` không có trạng thái (healthy) | Container treo vẫn được coi là "Up"; compose không biết khi nào sẵn sàng | `HEALTHCHECK` gọi `/healthz` bằng python |
| 9 | Không pin phiên bản base image | `FROM python:3.12` – tag trôi (đang 3.12.15, Debian 13.7) | Build lại hôm khác ra image khác → khó tái lập, khó điều tra lỗi | Pin `python:3.12.x-slim` hoặc pin digest `@sha256:...` |
| 10 | Thư viện có CVE | trivy: starlette 0.41.3 – 3 HIGH, có bản vá | DoS, SSRF | Nâng fastapi/starlette; quét trivy trong CI (Lab 04, 08) |
| 11 | Không có label OCI | `docker inspect` không có `org.opencontainers.image.*` | Không biết image build từ commit/phiên bản nào | `LABEL org.opencontainers.image.source/version/revision` |

## Bài học ngoài lề
- Ctrl-C trên `docker run` (không `-d`) không chắc dừng container → luôn kiểm tra `docker ps -a`.
- `grep pass` không ra ≠ không có secret (mật khẩu nằm trong `DATABASE_URL`).
