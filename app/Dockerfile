# syntax=docker/dockerfile:1.7
# ---- Stage 1: build wheels (có compiler, không đưa vào image cuối) ----
FROM python:3.12-slim AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt

# ---- Stage 2: runtime tối giản ----
FROM python:3.12-slim AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="shopmini" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/<your-user>/devops-labs"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} PYTHONPATH=/app/src PORT=8000
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
WORKDIR /app
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && rm -rf /wheels
COPY --chown=app:app src/ ./src/
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"
# exec form → uvicorn là PID 1, nhận SIGTERM để graceful shutdown
CMD ["sh", "-c", "exec uvicorn shopmini.main:app --host 0.0.0.0 --port ${PORT} --workers ${WORKERS:-2} --timeout-graceful-shutdown 20"]
