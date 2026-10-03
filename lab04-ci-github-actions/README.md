# Lab 04 – CI với GitHub Actions: test, build, scan, SBOM, release

> **Thời lượng:** 3–4 giờ · **Chạy ở:** GitHub (repo public, Actions miễn phí) + `act` để chạy thử local · **Chi phí:** 0

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Pipeline gồm: lint → unit test (coverage gate **≥ 85%**) → hadolint → build → **smoke test với Postgres thật** → Trivy → push GHCR | `verify.sh` |
| T2 | Pipeline trên `main` **< 6 phút** (nhờ cache pip và cache layer `type=gha`) | `gh run list` |
| T3 | Image có tag `sha-<commit>`, tag **semver** khi tạo git tag `vX.Y.Z`, kèm **SBOM + provenance** | GHCR |
| T4 | `main` được bảo vệ: phải qua PR và **status check xanh** mới merge được | Branch protection / Ruleset |
| T5 | Một PR cố ý làm test fail bị **chặn merge** (gắn label `lab04-red`) | `verify.sh` |
| T6 | Workflow dùng **quyền tối thiểu** (`permissions:`), không có secret dài hạn | review |
| T7 | Dependabot cập nhật pip / Docker base image / GitHub Actions hằng tuần | `.github/dependabot.yml` |

## Pipeline

```
 PR / push main / tag v*
        │
 ┌──────┴───────┐      ┌──────────────┐
 │ lint-test    │      │ hadolint     │      (chạy song song)
 │ ruff, pytest │      │ Dockerfile   │
 └──────┬───────┘      └──────┬───────┘
        └──────────┬──────────┘
          ┌────────▼─────────────────────────────────────────────┐
          │ build-scan-smoke                                      │
          │ buildx (cache gha) → docker run + Postgres service →  │
          │ Trivy CRITICAL (chặn) → SARIF → [không phải PR] push  │
          │ GHCR + SBOM + provenance                              │
          └────────┬─────────────────────────────────────────────┘
                   │ (chỉ khi tag v*)
             ┌─────▼─────┐
             │ release   │  GitHub Release + release notes tự sinh
             └───────────┘
```

## Kiến thức nền

- **CI (Continuous Integration):** mỗi thay đổi đều được build và test tự động, phát hiện lỗi **trước khi** merge. Pipeline càng nhanh thì vòng phản hồi càng ngắn.
- **`GITHUB_TOKEN`** là token tạm thời do GitHub cấp riêng cho mỗi lần chạy. Phạm vi quyền của nó do khối `permissions:` quyết định, nên không cần tạo Personal Access Token.
- **Tag bất biến:** `sha-abc1234` luôn trỏ đúng một commit, rất hợp để deploy và rollback. `latest` thì đổi liên tục, không biết đang chạy bản nào.
- **SBOM** (Software Bill of Materials) là danh sách mọi thành phần có trong image. Khi một CVE mới được công bố, SBOM giúp trả lời ngay "image nào của mình bị ảnh hưởng?".

---

## Bài 1 – Đưa workflow vào repo

```bash
cd ~/work/devops-labs
mkdir -p .github/workflows
cp lab04-ci-github-actions/workflows/ci.yml .github/workflows/ci.yml
cp lab04-ci-github-actions/workflows/dependabot.yml .github/dependabot.yml
cp lab04-ci-github-actions/workflows/pull_request_template.md .github/pull_request_template.md
git checkout -b feat/ci && git add .github && git commit -m "ci: add pipeline" && git push -u origin feat/ci
gh pr create --fill && gh pr checks --watch
```

Đọc từng job trong `ci.yml` và **giải thích từng dòng** vào `NOTES.md`, nhất là `concurrency`, `permissions`, `services`, `cache-from/cache-to`, và `if: github.event_name != 'pull_request'`.

## Bài 2 – Chạy thử local bằng `act`

```bash
act pull_request -j lint-test --container-architecture linux/amd64
act -l                                   # liệt kê job
```

Ghi lại: job nào chạy được bằng `act`, job nào không (gợi ý: `services`, cache `gha`, upload SARIF) và vì sao.

## Bài 3 – Nâng chất lượng (bắt buộc)

1. **Coverage ≥ 85%:** viết thêm test cho các nhánh chưa được phủ: `/readyz` khi DB lỗi (dùng `monkeypatch` thay `engine`), `/chaos` khi `CHAOS_ENABLED=false`, logic cache khi có Redis (dùng thư viện `fakeredis`). Sau đó đổi `--cov-fail-under=85`.
2. **Hadolint:** đổi `failure-threshold` thành `warning` rồi sửa Dockerfile cho đến khi hết cảnh báo.
3. **Tăng tốc:** đo thời gian từng job trong tab Actions. Thử bỏ `cache-from: type=gha`, chạy lại và so sánh. Ghi lại số liệu.
4. **Matrix:** chạy `lint-test` song song trên Python `3.12` và `3.13`.

<details><summary>Gợi ý test readyz khi DB lỗi</summary>

```python
def test_readyz_db_down(client, monkeypatch):
    import shopmini.main as m
    class Boom:
        def connect(self): raise RuntimeError("db down")
    monkeypatch.setattr(m, "engine", Boom())
    r = client.get("/readyz")
    assert r.status_code == 503 and r.json()["checks"]["database"].startswith("fail")
```
</details>

## Bài 4 – Bảo vệ `main` và PR "đỏ"

1. GitHub → Settings → **Rules → Rulesets → New branch ruleset** (hoặc Branch protection) cho `main`: *Require a pull request*, *Require status checks*: `Lint & unit test`, `Hadolint`, `Build → smoke test → scan → push`; chặn force push.
2. Tạo branch `demo/red`, sửa test cho fail (vd đổi `21.0` thành `22.0`), mở PR, gắn **label `lab04-red`**. PR phải hiện **"Merging is blocked"**. Chụp ảnh lưu vào `lab04-ci-github-actions/evidence/`.
3. Tạo thêm PR đổi base image sang `python:3.9-slim` (có nhiều CVE hơn). Trivy có chặn không? Nếu không, vì sao (`ignore-unfixed`, mức severity)?

## Bài 5 – Release theo semver

```bash
git checkout main && git pull
git tag -a v1.0.0 -m "shopmini 1.0.0" && git push origin v1.0.0
gh run watch
docker pull ghcr.io/<you>/shopmini:1.0.0
docker buildx imagetools inspect ghcr.io/<you>/shopmini:1.0.0 --format '{{ json .SBOM }}' | head -c 400
```

Đặt package GHCR ở chế độ **public** (Package settings) để Lab 05–08 kéo image không cần credential.

## Bài 6 – Chấm điểm

```bash
gh auth login && ./verify.sh
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Việc của bạn |
|---|---|---|
| B1 | Xóa `packages: write` khỏi job build | Push bị `denied: permission_denied`. Đọc log và giải thích mô hình quyền của `GITHUB_TOKEN` |
| B2 | Trong smoke test, đổi `localhost:5432` thành `postgres:5432` | Vì sao container chạy `--network host` không phân giải được tên service `postgres`, trong khi job chạy trong container thì phân giải được? |
| B3 | Thêm `echo ${{ secrets.GITHUB_TOKEN }}` vào một step | GitHub che (mask) giá trị. Vì sao in secret ra log vẫn là thói quen nguy hiểm? (base64, ký tự bị tách…) |
| B4 | Push 3 commit liên tiếp thật nhanh | Chỉ lần chạy cuối hoàn thành, các lần trước bị hủy → nhờ `concurrency` |
| B5 | Pin `actions/checkout@v4` thành một commit SHA sai | Workflow lỗi ngay. Sau đó tìm hiểu vì sao các tổ chức lớn bắt buộc **pin action theo SHA** (sự cố `tj-actions/changed-files` năm 2025) |

## 🚀 Thử thách mở rộng

- Dùng **release-please** để tự sinh CHANGELOG và version từ Conventional Commits.
- Thêm job **integration test** dùng `docker compose` của Lab 01 kèm k6 smoke (10 VU / 20s).
- Tạo **reusable workflow** (`workflow_call`) cho phần build-scan-push để các service khác dùng lại.
- Cấu hình **GitHub Environments** (`staging`, `production`) có required reviewers, chuẩn bị cho CD ở Lab 06.

## ❓ Câu hỏi tự kiểm tra

1. CI, Continuous Delivery và Continuous Deployment khác nhau thế nào?
2. Vì sao không nên build image hai lần cho staging và production? ("build once, deploy many")
3. `pull_request` và `pull_request_target` khác nhau thế nào về bảo mật?
4. Cache `type=gha` hoạt động ra sao? Khi nào cache bị mất?
5. Pipeline đỏ vì một test "flaky" (lúc pass lúc fail). Bạn xử lý thế nào?

## Tham khảo

- [docker/build-push-action](https://github.com/docker/build-push-action), [docker/metadata-action](https://github.com/docker/metadata-action)
- [aquasecurity/trivy-action](https://github.com/aquasecurity/trivy-action), [hadolint/hadolint](https://github.com/hadolint/hadolint)
- [nektos/act](https://github.com/nektos/act), [rhysd/actionlint](https://github.com/rhysd/actionlint)
- [googleapis/release-please](https://github.com/googleapis/release-please)
