# Lab 06 – GitOps với Argo CD, Sealed Secrets & Argo Rollouts

> **Thời lượng:** 4–5 giờ · **Chạy ở:** Local (cluster kind của Lab 05) + GitHub · **Chi phí:** 0 · **Yêu cầu:** Lab 04 (image trên GHCR, public), Lab 05 (cluster + base manifest)

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | **App of Apps**: chỉ `kubectl apply` đúng một lần (root app), mọi thứ còn lại do Argo CD đồng bộ từ Git | `verify.sh` |
| T2 | `shopmini-dev` và `shopmini-prod` đều **Synced/Healthy**; AppProject giới hạn repo và namespace | `verify.sh` |
| T3 | **Không có secret plaintext trong Git**: dùng SealedSecret | `verify.sh` |
| T4 | Luồng CD tự động: merge code → CI build → bot commit tag mới vào `envs/dev` → Argo CD deploy, **không ai chạy kubectl** | `verify.sh` |
| T5 | **Self-heal**: sửa tay tài nguyên trong cluster → Argo CD đưa về trạng thái Git trong **≤ 3 phút** | `DRIFT=1 ./verify.sh` |
| T6 | Prod deploy bằng **canary 20% → 50% → 100%** có analysis; bản hỏng **tự rollback** | `verify.sh` |
| T7 | Promote dev → prod **chỉ qua Pull Request**; rollback bằng `git revert` | Bài 6 |

## Kiến trúc

```
  Developer ──push──▶ GitHub repo (devops-labs)
                         │  app/**  ──▶ [ci.yml] build → GHCR ghcr.io/<you>/shopmini:sha-xxxx
                         │                     │ workflow_run
                         │                     ▼
                         │            [cd-bump.yml] kustomize edit set image → commit envs/dev
                         │  envs/prod ◀── [promote.yml] mở PR ──▶ bạn review & merge
                         │
            pull (60s)   ▼
  ┌──────────────── kind cluster ────────────────────────────────────────┐
  │ Argo CD: root ──▶ AppProject shop, shopmini-dev, shopmini-prod        │
  │ Sealed Secrets controller: SealedSecret ──giải mã──▶ Secret           │
  │ shop-dev : Deployment (rolling)                                       │
  │ shop-prod: Rollout(workloadRef) canary qua ingress-nginx + Analysis   │
  └───────────────────────────────────────────────────────────────────────┘
```

## Kiến thức nền

- **Push và pull deploy:** với push, pipeline cầm kubeconfig và chạy `kubectl apply`. Với GitOps (pull), agent nằm **trong** cluster tự kéo trạng thái từ Git, nên CI không bao giờ có quyền vào cluster.
- **Git là nguồn sự thật duy nhất**: muốn đổi gì thì commit, muốn rollback thì `git revert`, lịch sử audit chính là `git log`.
- **SealedSecret** được mã hóa bằng public key của controller trong cluster, chỉ controller đó mới giải mã được. Vì vậy commit lên Git public vẫn an toàn (nhưng mất controller hoặc key là mất secret, nên phải backup key).
- **Canary** chuyển một phần nhỏ traffic sang bản mới và **đo** sức khỏe trước khi mở rộng. Argo Rollouts tự động hóa các bước này và tự rollback khi analysis thất bại.

---

## Bài 1 – Chuẩn bị repo

```bash
cd ~/work/devops-labs
./lab06-gitops-argocd/scripts/set-repo.sh <github-user-viết-thường>
git add -A && git commit -m "gitops: set repo url" && git push
```

## Bài 2 – Cài nền tảng & root app

```bash
kubectl config use-context kind-devops        # cluster từ Lab 05
kubectl delete ns shop-dev shop-prod --ignore-not-found   # từ giờ Argo CD quản lý 2 namespace này
./lab06-gitops-argocd/bootstrap/install.sh
```

Ứng dụng sẽ chưa Healthy vì **chưa có secret DB**:

```bash
./lab06-gitops-argocd/scripts/seal-db-secret.sh dev
./lab06-gitops-argocd/scripts/seal-db-secret.sh prod
cat lab06-gitops-argocd/gitops/envs/dev/sealed-db.yaml     # chỉ thấy chuỗi đã mã hóa
git add lab06-gitops-argocd/gitops/envs/*/sealed-db.yaml && git commit -m "gitops: sealed db secrets" && git push
argocd app list   # hoặc mở UI: http://argocd.127.0.0.1.nip.io
```

> ⚠️ Nhớ thêm NetworkPolicy cho Redis (Lab 05, Bài 4) vào `lab05-kubernetes/k8s/base` và **commit** lên. Nếu chỉ `kubectl apply` thì Argo CD sẽ xóa nó, vì nó không có trong Git.

**TODO:** backup private key của Sealed Secrets controller (`kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/sealed-key-backup.yaml`, **không commit**). Giải thích: nếu xóa cluster rồi tạo lại mà không có key này thì chuyện gì xảy ra?

## Bài 3 – Self-heal & prune

```bash
kubectl -n shop-dev scale deploy/shopmini --replicas=5      # HPA hay Argo CD sẽ "thắng"? Vì sao?
kubectl -n shop-dev edit configmap shopmini-config           # đổi LOG_LEVEL=DEBUG → chờ 1–3 phút
kubectl -n shop-dev create configmap rogue --from-literal=a=b   # tài nguyên KHÔNG có trong Git → prune có xóa không?
```

Ghi lại bằng chứng (ảnh UI, `argocd app history shopmini-dev`). Giải thích khác nhau giữa **selfHeal**, **prune** và vì sao `rogue` không bị xóa (gợi ý: Argo CD chỉ prune những gì nó đã từng quản lý, tức có tracking label/annotation).

## Bài 4 – Luồng CD tự động (CI → Git → Argo CD)

1. Tạo **deploy key** có quyền ghi:
   ```bash
   ssh-keygen -t ed25519 -N "" -f /tmp/gitops-bot -C gitops-bot
   gh repo deploy-key add /tmp/gitops-bot.pub --allow-write --title gitops-bot
   gh secret set GITOPS_DEPLOY_KEY < /tmp/gitops-bot && rm /tmp/gitops-bot*
   ```
2. Trong **ruleset** của `main` (Lab 04), thêm **Deploy keys** vào *Bypass list*, để bot được push thẳng vào `main` còn người thì vẫn phải qua PR.
3. `cp lab06-gitops-argocd/workflows/{cd-bump,promote}.yml .github/workflows/`, commit qua PR.
4. Sửa app (ví dụ thêm field `"region": "local"` vào `GET /`), mở PR, merge. Theo dõi: `ci` xanh → `cd-bump` commit → Argo CD sync → `curl http://shop.127.0.0.1.nip.io/` thấy thay đổi.

**Target T4:** đo thời gian **từ lúc merge đến lúc thay đổi chạy trong cluster**, ghi vào `NOTES.md`. Rút ngắn được bằng cách nào? (Argo CD webhook, giảm `timeout.reconciliation`…)

## Bài 5 – Canary ở prod với Argo Rollouts

```bash
kubectl argo rollouts get rollout shopmini -n shop-prod --watch
```

1. **Canary thành công:** chạy workflow `promote-to-prod` với tag đã chạy ở dev, merge PR, rồi quan sát các bước `20% → pause → 50% → pause → 100%`. Trong lúc đó chạy `curl -s http://shop-prod.127.0.0.1.nip.io/ -D- | grep x-app-version` nhiều lần để thấy traffic được chia.
2. **Canary hỏng:** giả lập bản phát hành lỗi bằng biến `FAIL_READINESS=true` (app sẽ trả `/readyz` = 503). Thêm patch sau vào `envs/prod/kustomization.yaml` qua một PR:
   ```yaml
     - target: { kind: Deployment, name: shopmini }
       patch: |-
         - op: add
           path: /spec/template/spec/containers/0/env/-
           value: { name: FAIL_READINESS, value: "true" }
   ```
   Pod template thay đổi nên canary bắt đầu chạy. Pod canary không bao giờ Ready, AnalysisRun **Failed**, Rollout chuyển sang **Degraded/Aborted**, traffic quay về 100% bản stable. Người dùng gần như không bị ảnh hưởng.
3. Dọn: `git revert` PR promote hỏng, để Git và cluster khớp nhau trở lại.

**TODO:** vẽ sơ đồ trạng thái (Progressing → Paused → Healthy / Degraded) vào `NOTES.md`.

## Bài 6 – Rollback đúng kiểu GitOps

So sánh 3 cách rollback và ghi ưu nhược điểm của từng cách:

| Cách | Lệnh | Git còn khớp cluster không? |
|---|---|---|
| A | `kubectl argo rollouts undo shopmini -n shop-prod` | ? |
| B | `argocd app rollback shopmini-prod <id>` (cần tắt auto-sync) | ? |
| C | `git revert <commit-promote> && git push` | ? |

## Bài 7 – Chấm điểm

```bash
./verify.sh
DRIFT=1 ./verify.sh
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Triệu chứng / Hướng điều tra |
|---|---|---|
| B1 | Commit một manifest YAML sai cú pháp vào `envs/dev` | App `ComparisonError`/`Unknown`. Đọc `argocd app get shopmini-dev`. Thêm bước `kustomize build` + `kubeconform` vào CI để chặn từ PR |
| B2 | Xóa Sealed Secrets controller rồi cài lại | Secret không giải mã được (`no key could decrypt secret`). Khôi phục bằng key đã backup ở Bài 2 |
| B3 | Commit `newTag: "khong-ton-tai"` vào dev | `ImagePullBackOff`, app Degraded. Rollback bằng `git revert` |
| B4 | Đổi `targetRevision` của dev thành `feature/x` (không tồn tại) | App báo lỗi repo. Phân biệt lỗi Git với lỗi cluster |
| B5 | Bỏ NetworkPolicy `api-ingress-from-argo-rollouts` | AnalysisRun timeout → canary bị abort dù bản mới hoàn toàn tốt. Bài học: hạ tầng giám sát cũng cần quyền mạng |
| B6 | Xóa `ignoreDifferences` ở `shopmini-prod` | Argo CD và Rollouts "giành nhau" field `replicas` (app OutOfSync liên tục) |

## 🚀 Thử thách mở rộng

- Dùng **ApplicationSet** (generator `list` hoặc `git directories`) để sinh app cho dev/staging/prod từ một template.
- Thay `cd-bump.yml` bằng **Argo CD Image Updater**, hoặc chuyển sang **Flux** (image automation) và so sánh hai cách.
- Bật **Argo CD Notifications** gửi tin vào Slack/Discord khi sync fail hoặc app Degraded.
- Cấu hình **SSO GitHub** + RBAC cho Argo CD: nhóm `dev` chỉ được sync `shopmini-dev`.

## 🧹 Cleanup

Giữ cluster cho Lab 07–08. Khi xong hẳn: `kind delete cluster --name devops`, xóa deploy key và secret `GITOPS_DEPLOY_KEY`.

## ❓ Câu hỏi tự kiểm tra

1. Nêu 4 nguyên tắc của GitOps (OpenGitOps). Hệ thống của bạn đã đáp ứng nguyên tắc nào, còn thiếu nguyên tắc nào?
2. Vì sao "CI ghi vào Git" an toàn hơn "CI chạy `kubectl apply`"?
3. Sync wave và sync hook dùng để làm gì? Cho ví dụ chạy migration DB trước khi deploy app.
4. Canary và blue/green khác nhau thế nào khi dùng Argo Rollouts?
5. Nếu Git (GitHub) bị sự cố thì ứng dụng đang chạy có bị ảnh hưởng không? Deploy khẩn cấp lúc đó làm thế nào?

## Tham khảo

- [argoproj/argo-cd](https://github.com/argoproj/argo-cd), [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps)
- [argoproj/argo-rollouts](https://github.com/argoproj/argo-rollouts): tài liệu *Rollout workloadRef* và *NGINX traffic routing*
- [bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
- [open-gitops/documents](https://github.com/open-gitops/documents): định nghĩa các nguyên tắc GitOps
