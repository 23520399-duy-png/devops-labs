# Lab 07 – Observability: Prometheus, Grafana, Loki, SLO & alerting

> **Thời lượng:** 5–6 giờ · **Chạy ở:** Local (cluster kind của Lab 05/06) · **Chi phí:** 0 · **RAM:** stack này dùng thêm ~3 GB

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | kube-prometheus-stack + Loki + Alloy chạy ổn định, được truy cập qua ingress | `verify.sh` |
| T2 | Prometheus scrape được **mọi pod** shopmini qua ServiceMonitor (mở NetworkPolicy đúng chỗ) | `up{job="shopmini"}` |
| T3 | Có **SLI/SLO** dạng recording rule; alert **multi-window burn-rate** (page + ticket) | `verify.sh` |
| T4 | Dashboard **RED + SLO** (rate, errors, duration, error budget, log lỗi) được cấp tự động (dashboard as code) | Grafana |
| T5 | Bơm 30% lỗi → alert **page** tới "người trực" (webhook) trong **≤ 5 phút**, tự **resolved** khi hết lỗi | `FIRE=1 ./verify.sh` |
| T6 | Từ một alert lần ra log lỗi tương ứng trong Loki trong **< 2 phút** (metrics → logs) | Bài 5 |
| T7 | Canary ở prod dùng **Prometheus analysis** (tỷ lệ lỗi của bản canary) thay cho `/readyz` | Bài 7 |
| T8 | Có `RUNBOOK.md` cho mọi alert và **một postmortem** cho sự cố đã gây ra | review |

## Kiến trúc

```
  shopmini pods ──/metrics──▶ Prometheus ──rules──▶ recording (SLI) ──▶ alerts ──▶ Alertmanager ──▶ alert-receiver (người trực)
       │ stdout JSON                 │                                                       │
       ▼                              ▼                                                       ▼
  Alloy (DaemonSet) ──▶ Loki ──▶ Grafana (dashboard RED/SLO + Explore logs) ◀─────────────────┘
                                     ▲
  Argo Rollouts AnalysisTemplate ────┘ (query Prometheus: error ratio của canary)
```

## Kiến thức nền

- **RED** cho service: **R**ate, **E**rrors, **D**uration. **USE** cho tài nguyên: Utilization, Saturation, Errors.
- **SLI → SLO → Error budget:** SLI = tỷ lệ request không lỗi 5xx; SLO = 99,5% trong 30 ngày, tức budget = 0,5% (≈ 3,6 giờ "lỗi hoàn toàn" mỗi tháng).
- **Burn rate** là tốc độ tiêu budget so với tốc độ "vừa đủ hết đúng 30 ngày". Burn rate 14,4 trong 1 giờ nghĩa là tiêu 2% budget trong 1 giờ, phải gọi người ngay. Cách cảnh báo **multi-window** (1h **và** 5m) vừa ít báo động giả, vừa tự tắt nhanh khi đã hết lỗi.
- **Cardinality:** mỗi tổ hợp label là một time series riêng. Không bao giờ dùng `user_id` hay `order_id` làm label. App này dùng label `route` (template như `/orders/{order_id}`) chứ không dùng path thật, chính vì lý do này.

---

## Bài 1 – Cài stack

```bash
cd lab07-observability
./scripts/install.sh
kubectl -n monitoring get pods
```

Vào Grafana (`admin / devops-labs`), xem các dashboard có sẵn: *Kubernetes / Compute Resources / Namespace (Pods)*, *Node Exporter*.

## Bài 2 – Đưa shopmini vào giám sát (bằng GitOps)

Thêm `../../../../lab07-observability/k8s` vào `resources` của `lab06-gitops-argocd/gitops/envs/dev/kustomization.yaml` (và prod), commit, push. Argo CD sẽ tạo ServiceMonitor, NetworkPolicy và PrometheusRule.

```bash
# Có traffic để có dữ liệu
BASE_URL=http://shop.127.0.0.1.nip.io VUS=5 DURATION=30m k6 run ../lab05-kubernetes/loadtest/k6-k8s.js &
```

Mở Prometheus → *Status → Targets*, tìm `serviceMonitor/shop-dev/shopmini`. **Nếu target DOWN**, chẩn đoán xem là NetworkPolicy, port name hay label selector.

**TODO:** viết 5 câu PromQL vào `NOTES.md` và giải thích từng câu:
1. Request/giây của shopmini theo `route`.
2. Tỷ lệ lỗi 5xx trong 5 phút.
3. p99 latency của `POST /orders`.
4. Pod nào dùng nhiều memory nhất trong namespace.
5. Số lần container api bị restart trong 1 giờ (`kube_pod_container_status_restarts_total`).

## Bài 3 – Đọc hiểu SLO & alert

Mở `k8s/slo-rules.yaml`. **TODO:** tính và ghi lại:
- SLO 99,5%/30 ngày cho phép bao nhiêu **phút** lỗi hoàn toàn?
- Với burn rate 14,4, budget 30 ngày cạn sau bao lâu?
- Vì sao cần điều kiện `and ...ratio_rate5m`? Nếu bỏ đi thì alert sẽ tự tắt chậm đến mức nào sau khi đã hết lỗi?

## Bài 4 – Gây sự cố, nhận cảnh báo

```bash
kubectl -n monitoring logs -f deploy/alert-receiver &        # "điện thoại" của người trực
./scripts/chaos.sh shop-dev 0.3 0                            # 30% request lỗi 500
# quan sát: dashboard → Error ratio tăng; Prometheus → Alerts: pending → firing; receiver nhận JSON
./scripts/chaos.sh shop-dev 0 0                              # hết sự cố → đợi "resolved"
./scripts/chaos.sh shop-dev 0 900                            # thử latency → alert nào bắn? sau bao lâu?
```

Ghi lại **timeline** chính xác: lúc bơm lỗi, alert pending, alert firing, receiver nhận được, resolved. Đây là số liệu để tính **MTTD** (mean time to detect).

## Bài 5 – Từ metric sang log

Trong Grafana → Explore → Loki:

```logql
{namespace="shop-dev", app="shopmini"} | json | status >= 500
sum by (path) (count_over_time({namespace="shop-dev", app="shopmini"} | json | status >= 500 [5m]))
{namespace="shop-dev", app="shopmini"} | json | duration_ms > 500 | line_format "{{.request_id}} {{.path}} {{.duration_ms}}ms"
```

**TODO:** thêm vào dashboard một panel *Top route lỗi (Loki)*, rồi **export JSON** và cập nhật `dashboards/shopmini-red.json` (dashboard as code: mọi chỉnh sửa trên UI đều phải đưa về Git).

## Bài 6 – Runbook & postmortem

Hoàn thiện `RUNBOOK.md` (các mục TODO), rồi viết **postmortem** cho sự cố ở Bài 4, dùng số liệu timeline thật.

## Bài 7 – Canary dùng Prometheus analysis (nối với Lab 06)

1. Thêm nhãn `app.kubernetes.io/name: shopmini` vào Service `shopmini-canary` (trong `gitops/envs/prod/rollout.yaml`) để ServiceMonitor scrape được canary riêng (`job="shopmini-canary"`).
2. Thêm NetworkPolicy cho phép namespace `argo-rollouts` gọi `kps-prometheus.monitoring:9090` (monitoring không có default-deny, nên có thể bỏ qua bước này; ghi lại lý do).
3. **TODO:** thay metric `canary-readyz` bằng metric Prometheus: canary **fail** nếu tỷ lệ 5xx của `job="shopmini-canary"` > 2% trong 2 lần đo.

<details><summary>Lời giải AnalysisTemplate</summary>

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: canary-health
spec:
  metrics:
    - name: canary-error-ratio
      interval: 30s
      count: 6
      failureLimit: 1
      successCondition: len(result) == 0 || isNaN(result[0]) || result[0] < 0.02
      provider:
        prometheus:
          address: http://kps-prometheus.monitoring.svc:9090
          query: |
            sum(rate(http_requests_total{job="shopmini-canary",namespace="shop-prod",status=~"5.."}[1m]))
            /
            sum(rate(http_requests_total{job="shopmini-canary",namespace="shop-prod"}[1m]))
```
</details>

4. Thử nghiệm: promote một bản ổn, canary phải thành công. Sau đó tạo PR thêm env vào Deployment ở prod để giả lập bản phát hành lỗi:
   ```yaml
     - target: { kind: Deployment, name: shopmini }
       patch: |-
         - op: add
           path: /spec/template/spec/containers/0/env/-
           value: { name: CHAOS_ENABLED, value: "true" }
         - op: add
           path: /spec/template/spec/containers/0/env/-
           value: { name: CHAOS_ERROR_RATE, value: "0.5" }
   ```
   Pod canary vẫn **Ready** (vì `/readyz` không bị chaos ảnh hưởng), nên kiểu analysis cũ của Lab 06 sẽ **không phát hiện được** lỗi này. Analysis Prometheus phải **fail** và tự rollback. Đây là lý do nên phân tích bằng **metric người dùng thật** chứ không chỉ bằng health check.

## Bài 8 – Chấm điểm

```bash
./verify.sh
FIRE=1 ./verify.sh
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Triệu chứng / Hướng điều tra |
|---|---|---|
| B1 | Đổi `port: http` trong ServiceMonitor thành `port: web` | Target biến mất (không phải DOWN). Phân biệt "không discover được" với "scrape lỗi" |
| B2 | Xóa NetworkPolicy `api-ingress-from-monitoring` | Target DOWN với lỗi `context deadline exceeded`. Alert `ShopminiNoTraffic` bắn sau 10 phút → kiểm chứng giá trị của alert "absent" |
| B3 | Thêm label `request_id` vào metric (sửa code) | Số series tăng vọt: `count({__name__=~"http_.*"})`, `prometheus_tsdb_head_series`. Bài học về cardinality |
| B4 | Xóa route `severity =~ ...` trong Alertmanager | Alert firing trên Prometheus nhưng không tới receiver → kiểm tra `amtool` / UI Alertmanager *Status* |
| B5 | Scale `alloy` DaemonSet về 0 (patch nodeSelector không khớp) | Log ngừng chảy về Loki. Viết alert "log pipeline chết" dùng metric của Loki/Alloy |
| B6 | Đặt `retention: 2h` cho Prometheus | Recording rule 6h trả kết quả sai hoặc rỗng. Vì sao? |

## 🚀 Thử thách mở rộng

- **Tracing:** thêm OpenTelemetry SDK cho FastAPI, gửi trace qua Alloy (OTLP) tới **Tempo**, rồi liên kết trace với log qua `trace_id` (exemplars).
- Dùng **Sloth** hoặc **Pyrra** để sinh rule SLO từ một file spec ngắn và so sánh với rule viết tay.
- Viết **unit test cho alert rule** bằng `promtool test rules`.
- Quản lý dashboard bằng **Grafonnet/Jsonnet** hoặc Terraform provider Grafana.

## 🧹 Cleanup

`helm uninstall kps loki alloy -n monitoring && kubectl delete ns monitoring` (giữ lại nếu còn làm Lab 08).

## ❓ Câu hỏi tự kiểm tra

1. Pull model của Prometheus khác push model của CloudWatch thế nào? Short-lived job thì xử lý ra sao?
2. `rate()` khác `irate()` và `increase()` thế nào? Vì sao `rate()` phải đi với counter?
3. Histogram và summary khác nhau ra sao? Vì sao nên dùng histogram khi chạy nhiều pod?
4. Vì sao không nên alert trên CPU > 80%? Khi nào alert theo nguyên nhân (cause) là hợp lý?
5. Logs, metrics và traces: mỗi loại trả lời được câu hỏi gì? Cho ví dụ một sự cố cần dùng đủ cả ba.

## Tham khảo

- [prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts) (kube-prometheus-stack), [grafana/loki](https://github.com/grafana/loki), [grafana/alloy](https://github.com/grafana/alloy)
- [slok/sloth](https://github.com/slok/sloth), [pyrra-dev/pyrra](https://github.com/pyrra-dev/pyrra)
- Google SRE Workbook – *Alerting on SLOs* (nguồn gốc mô hình multi-window burn rate)
- [samber/awesome-prometheus-alerts](https://github.com/samber/awesome-prometheus-alerts)
