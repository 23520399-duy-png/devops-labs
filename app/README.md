# shopmini – ứng dụng mẫu cho bộ DevOps Labs

FastAPI + PostgreSQL (SQLite khi chạy test) + Redis (tùy chọn).

| Endpoint | Mô tả |
|---|---|
| `GET /` | tên service + version |
| `GET /healthz` | **liveness** – chỉ kiểm tra process |
| `GET /readyz` | **readiness** – kiểm tra DB (+ Redis nếu cấu hình); `FAIL_READINESS=true` để giả lập lỗi |
| `GET /metrics` | Prometheus: `http_requests_total`, `http_request_duration_seconds`, `shopmini_*` |
| `POST /orders` · `GET /orders` · `GET /orders/{id}` | nghiệp vụ |
| `POST /chaos?error_rate=0.3&latency_ms=500` | bơm lỗi (chỉ khi `CHAOS_ENABLED=true`) |

| Biến môi trường | Mặc định | Ý nghĩa |
|---|---|---|
| `DATABASE_URL` | `sqlite:///./shopmini.db` | hoặc dùng `DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME` |
| `REDIS_URL` | (trống) | bật cache khi có |
| `WORKERS` | 2 | số worker uvicorn |
| `CHAOS_ENABLED`, `CHAOS_ERROR_RATE`, `CHAOS_LATENCY_MS` | false, 0, 0 | fault injection |
| `FAIL_READINESS` | false | `/readyz` luôn 503 |
| `APP_VERSION`, `LOG_LEVEL`, `CACHE_TTL_SECONDS` | dev, INFO, 30 | |

```bash
make venv && make test && make lint && make run    # http://localhost:8000/docs
```
