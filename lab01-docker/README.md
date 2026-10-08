# Lab 01 – Docker & Docker Compose chuẩn production

> **Thời lượng:** 3–4 giờ · **Chạy ở:** Local (WSL2) · **Chi phí AWS:** 0 · **Yêu cầu:** Lab 00

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Image `shopmini:lab01` **< 200 MB**, chạy bằng **user non-root**, có **HEALTHCHECK**, không chứa secret, không có pytest/gcc | `docker image inspect`, `verify.sh` |
| T2 | **0 CVE CRITICAL** (loại đã có bản vá) | `trivy image --severity CRITICAL --ignore-unfixed` |
| T3 | Stack 4 service (nginx → api → postgres + redis) đều **healthy**; chỉ nginx publish port | `docker compose ps` |
| T4 | api chạy **read-only rootfs**, `cap_drop: ALL`, `no-new-privileges` | `verify.sh` |
| T5 | `docker compose stop api` dừng trong **≤ 10s** (graceful shutdown); process chết thì **tự khởi động lại** | `verify.sh` |
| T6 | Dữ liệu còn nguyên sau `docker compose down && up` | `verify.sh` |
| T7 | Tải **50 VU / 60s**: **p95 < 200 ms**, **lỗi < 1%** | `k6 run loadtest/k6-load.js` |

## Kiến trúc

```
            host:8080
               │
        ┌──────▼──────┐   frontend network
        │    nginx    │   (rate limit, gzip, chặn /metrics, request-id)
        └──────┬──────┘
               │ http://api:8000
        ┌──────▼──────┐
        │  api (x2    │   uvicorn workers, non-root, read-only rootfs
        │  workers)   │
        └───┬─────┬───┘   backend network (internal: true – không ra internet)
     ┌──────▼─┐ ┌─▼──────┐
     │postgres│ │ redis  │
     │ +volume│ │ LRU 64M│
     └────────┘ └────────┘
```

## Kiến thức nền

- **Layer & cache:** mỗi lệnh `RUN/COPY` tạo một layer. Hãy `COPY requirements.txt` và cài dependency **trước** khi `COPY` code, để sửa code không làm cài lại thư viện.
- **Multi-stage build:** stage `builder` có compiler để build wheel, còn stage `runtime` chỉ copy kết quả sang.
- **PID 1 & tín hiệu:** khi viết `CMD uvicorn ...` (shell form), `/bin/sh` là PID 1 và **không chuyển tiếp SIGTERM** cho uvicorn. Docker sẽ chờ 10 giây rồi SIGKILL, request đang xử lý bị cắt ngang. Dùng **exec form** `CMD ["…"]` hoặc `exec` trong shell.
- **healthcheck vs depends_on:** `depends_on` thông thường chỉ chờ container *start*. Muốn chờ *sẵn sàng* thì dùng `condition: service_healthy`.

---

## Bài 1 – Mổ xẻ Dockerfile "ngây thơ"

```bash
cd lab01-docker
docker build -f Dockerfile.naive -t shopmini:naive ../app
docker image ls shopmini                       # kích thước?
docker history shopmini:naive --no-trunc | head -20
docker run --rm shopmini:naive id              # chạy bằng user nào?
docker run --rm shopmini:naive env | grep -i pass
trivy image --severity HIGH,CRITICAL shopmini:naive | tail -30
```

**TODO:** ghi vào `NOTES.md` **ít nhất 8 vấn đề** của `Dockerfile.naive`, mỗi vấn đề kèm *rủi ro* và *cách sửa*. (Gợi ý: base image, thứ tự COPY, `.dockerignore`, công cụ dev trong image, secret trong ENV, root user, `--reload`, shell form, không có HEALTHCHECK, không pin version, không có label…)

## Bài 2 – Viết Dockerfile production của bạn

Tạo file **`lab01-docker/Dockerfile`** (build context là `../app`). Dockerfile phải:

- [ ] multi-stage (`builder` → `runtime`), base `python:3.12-slim`;
- [ ] cài dependency trước khi copy code (tận dụng cache);
- [ ] tạo user hệ thống UID 10001 và chạy bằng user đó;
- [ ] `HEALTHCHECK` gọi `/healthz` **mà không cần curl** (image slim không có curl);
- [ ] `CMD` dạng **exec**, số worker đọc từ biến `WORKERS`, có `--timeout-graceful-shutdown`;
- [ ] nhận `ARG APP_VERSION`, gắn label OCI (`org.opencontainers.image.*`).

```bash
docker compose build api && docker image ls shopmini:lab01
```

<details><summary>So sánh với bản tham chiếu (chỉ mở sau khi tự làm)</summary>

Xem `app/Dockerfile`. Câu hỏi để suy nghĩ thêm: chuyển sang `distroless` hoặc `chainguard/python` thì giảm được bao nhiêu MB và bao nhiêu CVE? Bù lại mất gì (không có shell để debug)?
</details>

## Bài 3 – Hoàn thiện `compose.yaml`

```bash
cp .env.example .env            # đổi mật khẩu; .env đã nằm trong .gitignore
```

Hoàn thành 4 TODO trong `compose.yaml`:

1. `api` chờ `db` và `cache` **healthy**.
2. `api`: `read_only: true`, `tmpfs: /tmp`, dùng anchor `*hardening`.
3. Giới hạn tài nguyên của `api`: 1 CPU / 384 MB.
4. `nginx` chờ `api` healthy và có healthcheck riêng.

```bash
docker compose up -d --build
docker compose ps                      # cả 4 service phải "healthy"
curl -i localhost:8080/readyz
curl -s -XPOST localhost:8080/orders -H 'content-type: application/json' \
     -d '{"customer":"duy","item":"book","quantity":2,"price":10}'
curl -s localhost:8080/orders | jq
docker compose logs -f api | jq -r '[.ts,.level,.status,.path,.duration_ms]|@tsv'   # log JSON
```

Lời giải: `solution/compose.yaml` (chạy bằng `docker compose -f solution/compose.yaml --env-file .env up -d`).

## Bài 4 – Test tải & tinh chỉnh

```bash
k6 run loadtest/k6-load.js
docker stats --no-stream
```

1. Ghi lại p50/p95/p99 và số req/s với `API_WORKERS=1`, `2`, `4` (sửa trong `.env`, chạy `docker compose up -d`). Vẽ bảng so sánh trong `NOTES.md`.
2. Gọi `GET /orders` nhiều lần và so sánh trường `cached` trong response. Sau đó xem metric `shopmini_cache_hits_total` bằng lệnh `docker compose exec api python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" | grep cache`.
3. **TODO:** giải thích vì sao tăng worker lên 8 trong khi limit chỉ có 1 CPU **không** làm hệ thống nhanh hơn.

## Bài 5 – Chấm điểm

```bash
./verify.sh            # QUICK=1 ./verify.sh để bỏ qua k6
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Việc của bạn |
|---|---|---|
| B1 | Đổi `CMD` trong Dockerfile của bạn sang **shell form** (`CMD uvicorn ...`), build lại, chạy `time docker compose stop api` | Giải thích vì sao mất đúng ~10 giây. Chứng minh bằng `docker compose exec api ps -o pid,cmd` (hoặc `cat /proc/1/cmdline`) |
| B2 | Xóa `depends_on … service_healthy` của api, chạy `docker compose down -v && docker compose up -d` | Quan sát log: api có kết nối DB khi DB chưa sẵn sàng không? App tự retry thế nào (xem `lifespan` trong `main.py`)? |
| B3 | Đặt memory limit của api còn `64M` | Container bị **OOMKilled** (exit code 137): tìm bằng `docker inspect -f '{{.State.OOMKilled}}'` |
| B4 | Sửa `DATABASE_URL` thành `...@localhost:5432/...` | Vì sao `localhost` trong container không phải là DB? Dùng `docker compose exec api getent hosts db` |
| B5 | Thêm vào nginx `rate=5r/s burst=5`, chạy k6 | Thấy 429 tăng vọt và k6 FAIL → đọc log JSON của nginx để chứng minh |
| B6 | `docker compose exec api sh -c 'echo hi > /app/x'` | Lỗi `Read-only file system`. Vậy app muốn ghi file tạm thì ghi vào đâu? |

## 🚀 Thử thách mở rộng

- Dùng **Docker secrets** (`secrets:` + `POSTGRES_PASSWORD_FILE`) thay cho biến môi trường. Sửa app để đọc mật khẩu từ file.
- Build **multi-arch** (`linux/amd64,linux/arm64`) bằng `docker buildx`, dùng cache mount `--mount=type=cache,target=/root/.cache/pip`.
- Thêm **backup** Postgres: service chạy `pg_dump` mỗi giờ vào volume `backups/`, giữ 24 bản gần nhất. Viết script restore và **thử restore thật**.
- So sánh image `python:3.12-slim` với `python:3.12-alpine` và `distroless`: kích thước, số CVE, thời gian build.

## ❓ Câu hỏi tự kiểm tra (hay gặp khi phỏng vấn)

1. `CMD` và `ENTRYPOINT` khác nhau thế nào? Khi nào dùng kết hợp?
2. Vì sao `COPY . .` trước `pip install` lại làm build chậm?
3. Liveness (`/healthz`) và readiness (`/readyz`) trong app này khác nhau ra sao? Vì sao liveness **không** kiểm tra DB?
4. `docker compose down` và `docker compose down -v` khác nhau thế nào?
5. Mạng `internal: true` có tác dụng bảo mật gì?

## Tham khảo

- Docker docs – *Best practices for writing Dockerfiles*, *Compose startup order*
- [stefanprodan/podinfo](https://github.com/stefanprodan/podinfo) – cách một app cloud-native xử lý health, metrics, graceful shutdown
- [hadolint/hadolint](https://github.com/hadolint/hadolint) – linter cho Dockerfile (nên chạy thử với Dockerfile của bạn)
