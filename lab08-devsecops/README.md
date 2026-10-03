# Lab 08 – DevSecOps: cổng bảo mật trong pipeline & policy-as-code trong cluster

> **Thời lượng:** 5–6 giờ · **Chạy ở:** GitHub Actions + cluster kind (Lab 05–07) · **Chi phí:** 0

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | Workflow `security` gồm 5 cổng: **secret** (gitleaks), **SAST** (semgrep), **SCA** (trivy fs), **IaC** (trivy config + checkov), **K8s policy** (kubeconform + kyverno CLI). `main` **xanh** | `verify.sh` |
| T2 | Mọi finding đã được **phân loại (triage)**: sửa, hoặc ignore **kèm lý do** + ngày xem lại | `.trivyignore`, `.checkov.yaml` |
| T3 | **≥ 4 PR "đỏ"** (secret, SAST, IaC, K8s) đều bị chặn merge | `verify.sh` |
| T4 | Image được **ký keyless bằng cosign** (OIDC GitHub, không có private key) + **SBOM attestation** | `cosign verify` |
| T5 | Kyverno **Enforce** trong `shop-*`: cấm `:latest`, bắt buộc resources/probe, chỉ registry tin cậy, **chỉ chạy image đã ký** | `verify.sh` |
| T6 | Image cũ chưa ký (`shopmini:1.0.0`) và `nginx:latest` bị **từ chối** ngay khi tạo pod | `kubectl --dry-run=server` |
| T7 | Lịch sử Git không có secret (gitleaks quét toàn bộ history) | `verify.sh` |

## Mô hình bảo vệ nhiều lớp

```
   Dev máy local         Pull Request (shift-left)                     main                       Cluster (runtime)
 ┌──────────────┐   ┌──────────────────────────────────┐   ┌───────────────────────────┐   ┌────────────────────────────┐
 │ pre-commit   │──▶│ gitleaks · semgrep · trivy fs     │──▶│ build (ci.yml) → cosign    │──▶│ Kyverno admission:         │
 │ gitleaks     │   │ trivy config · checkov            │   │ sign (keyless) + SBOM      │   │  verifyImages (chữ ký)     │
 └──────────────┘   │ kubeconform · kyverno CLI         │   │ attest → GHCR              │   │  latest/registry/resources │
                    │  ↳ FAIL = không merge được        │   └───────────────────────────┘   │ Pod Security "restricted"  │
                    └──────────────────────────────────┘                                    │ NetworkPolicy (Lab 05)     │
                                                                                             └────────────────────────────┘
```

## Kiến thức nền

- **Shift-left** nghĩa là tìm lỗi càng sớm càng rẻ: sửa một secret bị lộ ngay ở pre-commit gần như không tốn gì, còn nếu nó đã lên `main` của repo public thì phải coi như đã lộ và **xoay vòng** ngay.
- **Không có công cụ nào đủ một mình.** SAST đọc code, SCA đọc dependency, IaC scan đọc cấu hình hạ tầng, còn admission control là chốt chặn cuối cùng nếu mọi thứ phía trước bị vượt qua.
- **Ký keyless (Sigstore):** GitHub cấp OIDC token → Fulcio phát hành chứng chỉ ngắn hạn gắn với **danh tính workflow** → chữ ký được ghi vào log minh bạch Rekor. Kyverno kiểm tra "image này có phải do workflow X trong repo Y build ra không".
- **Triage:** không phải finding nào cũng phải sửa ngay. Kỹ năng quan trọng là đánh giá rủi ro thực tế, rồi **ghi lại quyết định** kèm người chịu trách nhiệm và hạn xem lại.

---

## Bài 1 – Pre-commit trên máy local

Tạo `.pre-commit-config.yaml` ở gốc repo:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks: [{ id: gitleaks }]
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks: [{ id: check-yaml, args: [--allow-multiple-documents] }, { id: end-of-file-fixer }, { id: detect-private-key }]
```

```bash
pre-commit install && pre-commit run --all-files
cp lab08-devsecops/vuln-samples/app/leaky_config.py app/src/shopmini/ && git add -A && git commit -m test   # phải bị chặn
git restore --staged . && rm app/src/shopmini/leaky_config.py
```

## Bài 2 – Đưa cổng bảo mật vào CI

```bash
cp lab08-devsecops/workflows/security.yml .github/workflows/
cp lab08-devsecops/root-configs/{.gitleaks.toml,.trivyignore,.checkov.yaml} .
git checkout -b feat/security && git add -A && git commit -m "ci: security gates" && git push -u origin feat/security
gh pr create --fill && gh pr checks --watch
```

Lần chạy đầu tiên **gần như chắc chắn đỏ**, vì code từ các lab trước có nhiều cấu hình chưa an toàn (ALB chỉ có HTTP, egress `0.0.0.0/0`, `force_destroy`…). Phần việc thật sự nằm ở Bài 3.

## Bài 3 – Triage finding (bắt buộc, quan trọng nhất)

Với **từng** finding HIGH/CRITICAL, quyết định một trong ba hướng rồi ghi bảng vào `lab08-devsecops/TRIAGE.md`:

| Finding | File | Quyết định | Lý do | Người / hạn xem lại |
|---|---|---|---|---|
| ví dụ AVD-AWS-0054 (ALB HTTP) | lab02/modules/web-asg | Chấp nhận tạm | Lab không có domain/ACM; prod sẽ dùng HTTPS + redirect | duy · 2026-12-31 |
| … | | **Sửa** / **Chấp nhận** / **False positive** | | |

Yêu cầu: **sửa thật** ít nhất 3 finding (ví dụ: bật ALB access logs, `drop_invalid_header_fields`, bật versioning/encryption, thu hẹp egress). Phần còn lại ignore **kèm comment lý do** trong `.trivyignore` / `.checkov.yaml`.

## Bài 4 – Chứng minh cổng hoạt động (4 PR "đỏ")

Với mỗi mẫu trong `vuln-samples/README.md`, tạo **một branch và một PR riêng**, gắn label `lab08-red`:

```bash
gh label create lab08-red --color B60205 2>/dev/null || true
git checkout -b demo/leak main
cp lab08-devsecops/vuln-samples/app/leaky_config.py app/src/shopmini/
git add -A && git commit -m "demo: leaked secret" --no-verify && git push -u origin demo/leak
gh pr create --fill --label lab08-red
```

Lặp lại với `report.py` (SAST), `open-sg.tf` (IaC), `privileged-patch.yaml` (K8s policy). Chụp màn hình check bị fail, lưu vào `evidence/`, sau đó **đóng PR, không merge**.

> ⚠️ Đã push secret lên GitHub (kể cả khi chỉ ở branch) thì phải coi như **đã lộ**. Trong thực tế, bước đầu tiên luôn là **xoay vòng (rotate) secret**, sau đó mới tính tới chuyện xóa khỏi lịch sử. Mẫu ở đây là giá trị giả nên không cần rotate.

## Bài 5 – Ký image & admission control

1. Merge `feat/security` vào `main`. Job `sign` ký image `sha-<commit>` theo **digest** và tạo SBOM attestation.
2. Kiểm tra:
   ```bash
   IMG=ghcr.io/<you>/shopmini:sha-<commit>
   cosign verify $IMG --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     --certificate-identity-regexp '^https://github.com/<you>/devops-labs/'
   cosign download attestation $IMG | jq -r .payload | base64 -d | jq '.predicate.packages | length'
   ```
3. Cài Kyverno và policy:
   ```bash
   ./lab08-devsecops/scripts/install-kyverno.sh
   kubectl -n shop-dev run t --image=nginx:latest --dry-run=server              # bị từ chối
   kubectl -n shop-dev run t --image=ghcr.io/<you>/shopmini:1.0.0 --dry-run=server   # chưa ký → bị từ chối
   kubectl get policyreport -A
   ```
4. **TODO (race condition):** `cd-bump` (Lab 06) có thể deploy tag mới **trước khi** job `sign` ký xong, khiến Kyverno chặn pod. Sửa `cd-bump.yml` để nó chạy sau workflow `security` (`workflow_run: workflows: [security]`), rồi giải thích vì sao thứ tự **build → scan → sign → deploy** là bắt buộc.
5. **TODO:** đưa Kyverno và các policy vào **GitOps** (thêm Application trong `lab06-gitops-argocd/gitops/apps/`), để policy cũng được quản lý bằng Git.

## Bài 6 – Chấm điểm

```bash
./lab08-devsecops/verify.sh
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Việc của bạn |
|---|---|---|
| B1 | Đổi `subjectRegExp` trong policy verify thành repo khác | Mọi pod shopmini mới bị chặn, kể cả image hợp lệ. Đọc event `kubectl get events -n shop-dev` và log Kyverno để tìm nguyên nhân |
| B2 | Kyverno admission controller chết (`kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=0`) | Pod mới có bị chặn hết không? Tìm hiểu `failurePolicy` (Fail/Ignore): đánh đổi giữa bảo mật và tính sẵn sàng |
| B3 | Đẩy lại tag `sha-xxx` trỏ tới image khác (ghi đè tag) | Vì sao ký **theo digest** và `mutateDigest: true` chống được kiểu tấn công này? |
| B4 | Thêm `# nosemgrep` vào dòng SQL injection | Cổng xanh trở lại. Đặt quy tắc review: ai được phép suppress và cần ghi lại ở đâu? |
| B5 | Cố tình commit secret thật (token GitHub tạm) vào branch rồi xóa ở commit sau | `gitleaks git` vẫn tìm thấy trong lịch sử. Thực hành: **revoke token** → `git filter-repo` → force push → nhờ GitHub xóa cache |

## 🚀 Thử thách mở rộng

- **DAST:** chạy OWASP ZAP baseline scan (`zaproxy/action-baseline`) vào môi trường dev qua ngrok/cloudflared, hoặc trong job dùng `docker compose` của Lab 01.
- **Runtime security:** cài **Falco**, rồi `kubectl exec` vào pod api và chạy `cat /etc/shadow` để thấy cảnh báo.
- **SLSA level 3:** dùng `slsa-framework/slsa-github-generator` để tạo provenance và verify bằng `slsa-verifier`.
- Gom finding vào **DefectDojo** (chạy bằng docker compose) để quản lý vòng đời lỗ hổng.
- Pin mọi GitHub Action theo **commit SHA** và để Dependabot tự cập nhật.

## ❓ Câu hỏi tự kiểm tra

1. SAST, DAST, SCA, IaC scanning: mỗi loại tìm được lỗi gì mà loại khác không tìm được?
2. Vì sao ký **theo digest** chứ không theo tag?
3. Kyverno/Gatekeeper (admission) khác Pod Security Admission thế nào? Có thể dùng cả hai không?
4. Một CVE CRITICAL trong base image chưa có bản vá: bạn xử lý thế nào để không chặn mọi lần release?
5. Giải thích "confused deputy" và cách OIDC trust policy giới hạn theo `sub` (repo/branch) ngăn nó.

## Tham khảo

- [gitleaks/gitleaks](https://github.com/gitleaks/gitleaks), [semgrep/semgrep](https://github.com/semgrep/semgrep), [aquasecurity/trivy](https://github.com/aquasecurity/trivy), [bridgecrewio/checkov](https://github.com/bridgecrewio/checkov)
- [sigstore/cosign](https://github.com/sigstore/cosign), [anchore/syft](https://github.com/anchore/syft)
- [kyverno/policies](https://github.com/kyverno/policies): thư viện policy mẫu (đã tham khảo cho `disallow-latest-tag`, `restrict-image-registries`, `verify-image`)
- OWASP DevSecOps Guideline, SLSA framework
