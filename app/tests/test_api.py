import importlib
import sys

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{tmp_path}/test.db")
    monkeypatch.setenv("CHAOS_ENABLED", "true")
    monkeypatch.delenv("REDIS_URL", raising=False)
    from prometheus_client import REGISTRY

    # Xóa metric đã đăng ký từ lần import trước để reload module không bị trùng.
    for collector in list(REGISTRY._collector_to_names):
        REGISTRY.unregister(collector)
    sys.modules.pop("shopmini.main", None)
    m = importlib.import_module("shopmini.main")
    with TestClient(m.app) as c:
        yield c


def test_health_and_ready(client):
    assert client.get("/healthz").json() == {"status": "ok"}
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["checks"]["database"] == "ok"


def test_create_and_get_order(client):
    r = client.post("/orders", json={"customer": "duy", "item": "book", "quantity": 2, "price": 10.5})
    assert r.status_code == 201
    body = r.json()
    assert body["total"] == 21.0
    assert client.get(f"/orders/{body['id']}").json()["item"] == "book"
    assert len(client.get("/orders").json()["items"]) == 1


def test_validation(client):
    r = client.post("/orders", json={"customer": "", "item": "x", "quantity": 0, "price": 1})
    assert r.status_code == 422


def test_not_found(client):
    assert client.get("/orders/999").status_code == 404


def test_metrics_and_headers(client):
    r = client.get("/")
    assert "x-request-id" in r.headers
    m = client.get("/metrics").text
    assert "http_requests_total" in m
    assert "shopmini_build_info" in m


def test_chaos_error_injection(client):
    assert client.post("/chaos", params={"error_rate": 1.0}).status_code == 200
    assert client.get("/orders").status_code == 500
    # health endpoints không bị ảnh hưởng bởi chaos
    assert client.get("/healthz").status_code == 200
    client.post("/chaos", params={"error_rate": 0.0})
    assert client.get("/orders").status_code == 200


def test_database_url_from_parts(monkeypatch):
    import shopmini.main as m

    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_HOST", "db.example")
    monkeypatch.setenv("DB_USER", "shop")
    monkeypatch.setenv("DB_PASSWORD", "p@ss:/word")
    url = m._database_url()
    assert url == "postgresql+psycopg://shop:p%40ss%3A%2Fword@db.example:5432/shop"
