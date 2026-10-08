"""shopmini – ứng dụng mẫu dùng xuyên suốt các bài lab DevOps.

Tính năng:
- REST API quản lý đơn hàng (orders) lưu trong PostgreSQL (hoặc SQLite khi chạy test).
- Cache đọc bằng Redis (tùy chọn – nếu không có REDIS_URL thì bỏ qua).
- /healthz (liveness), /readyz (readiness: kiểm tra DB + Redis), /metrics (Prometheus).
- Log JSON có request_id.
- Chế độ "chaos" (CHAOS_ENABLED=true) để cố ý gây lỗi / tăng độ trễ cho bài lab observability.
"""
from __future__ import annotations

import json
import logging
import os
import random
import sys
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Integer, Numeric, String, create_engine, func, select, text
from sqlalchemy.orm import declarative_base, sessionmaker

APP_VERSION = os.getenv("APP_VERSION", "dev")
def _database_url() -> str:
    """DATABASE_URL nếu có; nếu không thì ghép từ DB_HOST/DB_USER/DB_PASSWORD/DB_NAME
    (kiểu ECS + Secrets Manager: mật khẩu được inject riêng, không nằm trong URL cấu hình)."""
    if os.getenv("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    if os.getenv("DB_HOST"):
        from urllib.parse import quote_plus

        user = quote_plus(os.getenv("DB_USER", "shop"))
        pwd = quote_plus(os.getenv("DB_PASSWORD", ""))
        return (f"postgresql+psycopg://{user}:{pwd}@{os.environ['DB_HOST']}:"
                f"{os.getenv('DB_PORT', '5432')}/{os.getenv('DB_NAME', 'shop')}")
    return "sqlite:///./shopmini.db"


DATABASE_URL = _database_url()
REDIS_URL = os.getenv("REDIS_URL", "")
CHAOS_ENABLED = os.getenv("CHAOS_ENABLED", "false").lower() == "true"
CACHE_TTL = int(os.getenv("CACHE_TTL_SECONDS", "30"))


# ---------------------------------------------------------------- logging (JSON)
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "version": APP_VERSION,
        }
        for key in ("request_id", "path", "method", "status", "duration_ms"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), handlers=[handler], force=True)
log = logging.getLogger("shopmini")

# ---------------------------------------------------------------- metrics (RED)
REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
ORDERS_CREATED = Counter("shopmini_orders_created_total", "Orders created")
CACHE_HITS = Counter("shopmini_cache_hits_total", "Cache hits")
CACHE_MISSES = Counter("shopmini_cache_misses_total", "Cache misses")
INFO = Gauge("shopmini_build_info", "Build info", ["version"])
INFO.labels(version=APP_VERSION).set(1)

# ---------------------------------------------------------------- database
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {"connect_timeout": 3}
engine = create_engine(DATABASE_URL, pool_pre_ping=True, connect_args=connect_args)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
Base = declarative_base()


class Order(Base):
    __tablename__ = "orders"
    id = Column(Integer, primary_key=True, autoincrement=True)
    customer = Column(String(100), nullable=False)
    item = Column(String(100), nullable=False)
    quantity = Column(Integer, nullable=False)
    price = Column(Numeric(10, 2), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "customer": self.customer,
            "item": self.item,
            "quantity": self.quantity,
            "price": float(self.price),
            "total": round(float(self.price) * self.quantity, 2),
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class OrderIn(BaseModel):
    customer: str = Field(min_length=1, max_length=100)
    item: str = Field(min_length=1, max_length=100)
    quantity: int = Field(gt=0, le=1000)
    price: float = Field(gt=0, le=1_000_000)


# ---------------------------------------------------------------- redis (optional)
redis_client = None
if REDIS_URL:
    try:
        import redis  # type: ignore

        redis_client = redis.Redis.from_url(REDIS_URL, socket_timeout=1, socket_connect_timeout=1)
    except Exception:  # pragma: no cover
        log.exception("cannot init redis client")
        redis_client = None


def cache_get(key: str) -> Optional[dict]:
    if not redis_client:
        return None
    try:
        raw = redis_client.get(key)
    except Exception:
        log.warning("redis get failed")
        return None
    if raw is None:
        CACHE_MISSES.inc()
        return None
    CACHE_HITS.inc()
    return json.loads(raw)


def cache_set(key: str, value: dict) -> None:
    if redis_client:
        try:
            redis_client.setex(key, CACHE_TTL, json.dumps(value))
        except Exception:
            log.warning("redis set failed")


def cache_delete(key: str) -> None:
    if redis_client:
        try:
            redis_client.delete(key)
        except Exception:
            log.warning("redis delete failed")


# ---------------------------------------------------------------- chaos (fault injection)
chaos_state = {
    # Giá trị khởi tạo từ env – dùng để giả lập "bản phát hành lỗi" trong canary (Lab 07)
    "error_rate": float(os.getenv("CHAOS_ERROR_RATE", "0")) if CHAOS_ENABLED else 0.0,
    "latency_ms": int(os.getenv("CHAOS_LATENCY_MS", "0")) if CHAOS_ENABLED else 0,
}


# ---------------------------------------------------------------- app
@asynccontextmanager
async def lifespan(_: FastAPI):
    # Tạo bảng khi khởi động (thực tế nên dùng migration như Alembic).
    for attempt in range(1, 11):
        try:
            Base.metadata.create_all(engine)
            break
        except Exception as exc:  # DB chưa sẵn sàng → thử lại
            log.warning("database not ready (attempt %s): %s", attempt, exc)
            time.sleep(2)
    log.info("shopmini started", extra={"path": "-", "method": "-"})
    yield
    log.info("shopmini stopping – graceful shutdown")


app = FastAPI(title="shopmini", version=APP_VERSION, lifespan=lifespan)


def route_template(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", "unmatched")


@app.middleware("http")
async def observe(request: Request, call_next):
    request_id = request.headers.get("x-request-id", str(uuid.uuid4()))
    start = time.perf_counter()
    path = request.url.path
    status = 500
    try:
        if CHAOS_ENABLED and not path.startswith(("/chaos", "/metrics", "/healthz", "/readyz")):
            if chaos_state["latency_ms"]:
                time.sleep(chaos_state["latency_ms"] / 1000)
            if random.random() < chaos_state["error_rate"]:
                status = 500
                return Response(content='{"detail":"chaos: injected error"}', status_code=500,
                                media_type="application/json", headers={"x-request-id": request_id})
        response = await call_next(request)
        status = response.status_code
        response.headers["x-request-id"] = request_id
        response.headers["x-app-version"] = APP_VERSION
        return response
    finally:
        elapsed = time.perf_counter() - start
        route = route_template(request)
        if route != "/metrics":
            REQUESTS.labels(request.method, route, str(status)).inc()
            LATENCY.labels(request.method, route).observe(elapsed)
            log.info("request", extra={"request_id": request_id, "path": path, "method": request.method,
                                       "status": status, "duration_ms": round(elapsed * 1000, 1)})


@app.get("/")
def root():
    return {"service": "shopmini", "version": APP_VERSION}


@app.get("/healthz")
def healthz():
    """Liveness: chỉ kiểm tra process còn sống. KHÔNG kiểm tra DB (tránh restart dây chuyền)."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response):
    """Readiness: có sẵn sàng nhận traffic không (DB bắt buộc, Redis nếu có cấu hình)."""
    checks = {"database": "ok", "redis": "skipped"}
    ok = True
    if os.getenv("FAIL_READINESS", "false").lower() == "true":  # giả lập bản phát hành lỗi (Lab 06/07)
        response.status_code = 503
        return {"status": "broken", "checks": {"forced": "FAIL_READINESS=true"}}
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:
        checks["database"] = f"fail: {exc.__class__.__name__}"
        ok = False
    if redis_client:
        try:
            redis_client.ping()
            checks["redis"] = "ok"
        except Exception as exc:
            checks["redis"] = f"fail: {exc.__class__.__name__}"
            ok = False
    response.status_code = 200 if ok else 503
    return {"status": "ready" if ok else "not-ready", "checks": checks}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/orders", status_code=201)
def create_order(order: OrderIn):
    with SessionLocal() as db:
        row = Order(**order.model_dump())
        db.add(row)
        db.commit()
        db.refresh(row)
        ORDERS_CREATED.inc()
        cache_delete("orders:list")
        return row.to_dict()


@app.get("/orders")
def list_orders(limit: int = 20):
    limit = max(1, min(limit, 100))
    cache_key = "orders:list"
    if limit == 20 and (cached := cache_get(cache_key)) is not None:
        return {"items": cached, "cached": True}
    with SessionLocal() as db:
        rows = db.execute(select(Order).order_by(Order.id.desc()).limit(limit)).scalars().all()
        items = [r.to_dict() for r in rows]
    if limit == 20:
        cache_set(cache_key, items)
    return {"items": items, "cached": False}


@app.get("/orders/{order_id}")
def get_order(order_id: int):
    with SessionLocal() as db:
        row = db.get(Order, order_id)
        if not row:
            raise HTTPException(status_code=404, detail="order not found")
        return row.to_dict()


@app.post("/chaos")
def set_chaos(error_rate: float = 0.0, latency_ms: int = 0):
    """Bật lỗi giả lập: error_rate (0..1) và latency_ms. Chỉ hoạt động khi CHAOS_ENABLED=true."""
    if not CHAOS_ENABLED:
        raise HTTPException(status_code=403, detail="chaos disabled (set CHAOS_ENABLED=true)")
    chaos_state["error_rate"] = max(0.0, min(error_rate, 1.0))
    chaos_state["latency_ms"] = max(0, min(latency_ms, 10_000))
    log.warning("chaos updated: %s", chaos_state)
    return chaos_state


@app.get("/chaos")
def get_chaos():
    return {"enabled": CHAOS_ENABLED, **chaos_state}
