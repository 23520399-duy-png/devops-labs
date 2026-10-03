# Lab 05 – Kubernetes chuẩn production trên kind

> **Thời lượng:** 5–6 giờ · **Chạy ở:** Local (kind, 4 node) · **Chi phí:** 0 · **Yêu cầu:** Lab 01 (image), nên có Lab 04 (GHCR)

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Cluster 4 node (1 control-plane + 3 worker gắn nhãn `zone-a/b/c`), Calico, ingress-nginx, metrics-server | `verify.sh` |
| T2 | Namespace enforce **Pod Security `restricted`**: mọi pod non-root, drop ALL capabilities, seccomp | `verify.sh` |
| T3 | App + Postgres (StatefulSet + PVC) + Redis chạy ổn định; mọi container có **requests/limits** và **probe** | `verify.sh` |
| T4 | Pod api trải trên **≥ 2 zone** (topologySpreadConstraints) | `verify.sh` |
| T5 | **NetworkPolicy zero-trust**: pod lạ không vào được DB/Redis; api không ra được internet | `tests/netpol-test.sh` |
| T6 | `rollout restart` **dưới tải 20 VU: lỗi < 1%** (zero-downtime) | `FULL=1 ./verify.sh` |
| T7 | HPA scale **2 → ≥ 4 pod** dưới tải, rồi tự giảm lại | `FULL=1 ./verify.sh` |

## Kiến trúc

```
 host :80 ─▶ ingress-nginx (control-plane) ─▶ Service shopmini ─▶ Pod api ×2..6 (HPA)
                                                                   │  zone-a / zone-b / zone-c
                                     NetworkPolicy: default deny   ├──▶ postgres-0 (StatefulSet + PVC 1Gi)
                                     + allow DNS, ingress→api,     └──▶ redis (LRU cache)
                                       api→postgres, api→redis
 Kustomize:  k8s/base  ──▶ overlays/dev (shop-dev, image local, chaos on)
                      └─▶ overlays/prod (shop-prod, image GHCR, HPA 3–10, PDB 2)
```

## Kiến thức nền

- **Ba loại probe:** `startupProbe` (cho app khởi động chậm có thêm thời gian), `readinessProbe` (chưa sẵn sàng thì bị gỡ khỏi Service, **không** restart), `livenessProbe` (treo thì restart). Trong app này liveness = `/healthz` (chỉ kiểm tra process), readiness = `/readyz` (kiểm tra DB + Redis).
- **Zero-downtime rollout** cần đủ cả 4 yếu tố: `maxUnavailable: 0`, readiness probe chính xác, `preStop` sleep (chờ endpoint cập nhật), app xử lý SIGTERM gọn gàng.
- **requests vs limits:** scheduler xếp pod dựa trên `requests`; HPA tính `% CPU` cũng dựa trên **requests**. Container vượt memory limit thì bị **OOMKilled**, vượt CPU limit thì bị **throttle**.
- **NetworkPolicy** chỉ có hiệu lực khi CNI hỗ trợ (vì vậy lab dùng Calico). Khi đã có policy chọn một pod, mọi traffic không được "allow" tới pod đó đều bị chặn.

---

## Bài 1 – Dựng cluster

```bash
cd lab05-kubernetes
./scripts/cluster-up.sh
kubectl get nodes -L topology.kubernetes.io/zone
k9s                                   # khám phá cluster bằng giao diện terminal
```

## Bài 2 – Triển khai bằng Kustomize

```bash
./scripts/load-image.sh lab05                          # build + nạp image vào kind
cp k8s/overlays/dev/db.env.example k8s/overlays/dev/db.env
kubectl kustomize k8s/overlays/dev | less              # ĐỌC manifest cuối cùng trước khi apply
kubectl apply -k k8s/overlays/dev
kubectl -n shop-dev get pods -o wide -w
```

Bạn sẽ thấy pod `shopmini` **không bao giờ Ready**. Đây là chủ ý của bài, xem Bài 4.

```bash
kubectl -n shop-dev describe pod -l app.kubernetes.io/component=api | sed -n '/Events/,$p'
kubectl -n shop-dev logs deploy/shopmini | jq -r 'select(.level!="INFO") | .msg'
kubectl -n shop-dev exec deploy/shopmini -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/readyz').read())"
```

## Bài 3 – Pod Security Admission

Thử tạo một pod vi phạm chuẩn:

```bash
kubectl -n shop-dev run bad --image=nginx      # bị từ chối? Đọc kỹ thông báo lỗi
```

**TODO:** viết `tests/pod-root.yaml` chạy bằng root có `privileged: true`, apply vào `shop-dev` để thấy bị chặn. Apply vào namespace `default` thì sao? Giải thích sự khác nhau.

## Bài 4 – NetworkPolicy (bắt buộc)

`/readyz` báo `redis: fail` vì `default-deny-all` đang chặn traffic vào Redis.

**TODO:** viết policy `redis-ingress-from-api` trong `k8s/base/networkpolicy.yaml`: chỉ cho pod có nhãn `app.kubernetes.io/component: api` vào Redis ở port 6379. Apply lại rồi chạy:

```bash
./tests/netpol-test.sh shop-dev
# pod lạ → postgres:5432        BLOCKED
# pod lạ → redis:6379           BLOCKED
# pod mang nhãn api → postgres  OK
# pod mang nhãn api → redis     OK
# pod mang nhãn api → internet  BLOCKED
```

<details><summary>Lời giải</summary>

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis-ingress-from-api
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: redis }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app.kubernetes.io/component: api } }
      ports: [{ protocol: TCP, port: 6379 }]
```
</details>

## Bài 5 – Zero-downtime rollout & rollback

```bash
# Terminal 1 – tải liên tục
BASE_URL=http://shop.127.0.0.1.nip.io VUS=20 DURATION=5m k6 run loadtest/k6-k8s.js
# Terminal 2
./scripts/load-image.sh lab05-v2
kubectl -n shop-dev set image deploy/shopmini api=shopmini:lab05-v2
kubectl -n shop-dev rollout status deploy/shopmini
kubectl -n shop-dev rollout history deploy/shopmini
kubectl -n shop-dev rollout undo deploy/shopmini
```

**TODO:** lần lượt (1) xóa `preStop`, (2) đặt `maxUnavailable: 1`, (3) xóa `readinessProbe`. Với mỗi trường hợp, chạy rollout dưới tải và ghi tỷ lệ lỗi k6 vào bảng trong `NOTES.md`. Đây là bằng chứng bạn **hiểu** zero-downtime, không chỉ chép cấu hình.

## Bài 6 – HPA

```bash
kubectl -n shop-dev get hpa -w
BASE_URL=http://shop.127.0.0.1.nip.io VUS=60 SLEEP=0 DURATION=4m k6 run loadtest/k6-k8s.js
kubectl -n shop-dev top pods
```

**TODO:** giải thích công thức HPA `desired = ceil(current × currentMetric / target)`, và vì sao `scaleDown.stabilizationWindowSeconds` quan trọng. Sửa HPA để scale thêm theo **memory** (metric thứ hai).

## Bài 7 – Overlay production

```bash
cp k8s/overlays/prod/db.env.example k8s/overlays/prod/db.env
# sửa YOUR_GITHUB_USER trong overlays/prod/kustomization.yaml
kubectl apply -k k8s/overlays/prod
NS=shop-prod HOST=shop-prod.127.0.0.1.nip.io ./verify.sh
```

## Bài 8 – Chấm điểm

```bash
./verify.sh                 # nhanh
FULL=1 ./verify.sh          # thêm rollout dưới tải + HPA (~6 phút)
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Triệu chứng / Cách điều tra |
|---|---|---|
| B1 | `kubectl -n shop-dev set image deploy/shopmini api=shopmini:khong-ton-tai` | `ImagePullBackOff`. Nhờ `maxUnavailable: 0`, các pod cũ vẫn phục vụ. Rollback bằng `rollout undo` |
| B2 | Đổi memory limit của api thành `40Mi` | `OOMKilled` / `CrashLoopBackOff`. Dùng `kubectl describe` và `kubectl get pod -o jsonpath='{..lastState}'` |
| B3 | Đổi `readinessProbe.path` thành `/nope` | Pod Running nhưng 0/1 Ready, Service không còn endpoint, ingress trả 503. Dùng `kubectl get endpointslices` |
| B4 | `kubectl -n shop-dev delete pod postgres-0` | StatefulSet tạo lại **cùng tên, cùng PVC**: dữ liệu còn không? So sánh với `kubectl delete pvc` |
| B5 | `kubectl cordon` 2 worker rồi `drain` worker thứ 3 | Pod Pending vì không đủ chỗ. PDB ngăn drain làm sập dịch vụ ra sao? |
| B6 | Xóa policy `allow-dns-egress` | Mọi kết nối theo tên (`postgres`, `redis`) đều lỗi. Đây là lỗi kinh điển khi viết default-deny egress |
| B7 | Đặt `requests.cpu: 4` cho api | Pod `Pending` với thông báo `Insufficient cpu`. Giải thích bằng `kubectl describe node` (Allocated resources) |

## 🚀 Thử thách mở rộng

- Viết **Helm chart** cho shopmini (`helm create`), tham số hóa image, replicas, resources, ingress host, rồi so sánh với cách làm bằng Kustomize.
- Cài **cert-manager** + self-signed ClusterIssuer để bật HTTPS cho ingress.
- Thay Postgres tự quản bằng **CloudNativePG operator** (3 instance, failover tự động) và thử kill primary.
- Dùng **Velero** + MinIO để backup namespace và restore sang namespace khác.

## 🧹 Cleanup

```bash
kind delete cluster --name devops     # Lab 06–08 dùng lại cluster này – chỉ xóa khi xong cả 3 lab
```

## ❓ Câu hỏi tự kiểm tra

1. Deployment, StatefulSet, DaemonSet khác nhau thế nào? Vì sao Postgres dùng StatefulSet?
2. Một pod Pending: liệt kê 5 nguyên nhân có thể và lệnh để kiểm tra từng nguyên nhân.
3. Service ClusterIP tìm pod bằng cách nào (selector, EndpointSlice, kube-proxy)?
4. PDB bảo vệ khỏi loại gián đoạn nào, và **không** bảo vệ khỏi loại nào?
5. Vì sao `automountServiceAccountToken: false` là một biện pháp bảo mật?

## Tham khảo

- [kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind), [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx), [projectcalico/calico](https://github.com/projectcalico/calico)
- [ahmetb/kubernetes-network-policy-recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes): bộ ví dụ NetworkPolicy rất nên đọc
- [stefanprodan/podinfo – kustomize](https://github.com/stefanprodan/podinfo/tree/master/kustomize)
