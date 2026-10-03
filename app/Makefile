IMAGE ?= shopmini
TAG   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: venv test lint run build scan
venv:
	python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
test:
	.venv/bin/pytest -q
lint:
	.venv/bin/ruff check .
run:
	PYTHONPATH=src CHAOS_ENABLED=true .venv/bin/uvicorn shopmini.main:app --reload
build:
	docker build --build-arg APP_VERSION=$(TAG) -t $(IMAGE):$(TAG) .
scan:
	trivy image --severity HIGH,CRITICAL --exit-code 1 $(IMAGE):$(TAG)
