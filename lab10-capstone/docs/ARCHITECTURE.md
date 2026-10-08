# Kiến trúc nền tảng shopmini (Capstone)

> TODO: hoàn thiện tài liệu này bằng **tiếng Anh** – đây là tài liệu bạn sẽ đưa nhà tuyển dụng xem.

## 1. Context
- What the system does, who uses it.

## 2. Architecture diagram
- Draw: GitHub (CI, security, signing) → GHCR → Git (GitOps) → Argo CD → k3s on EC2 (ingress, app, Postgres, monitoring) → S3 backups.

## 3. Key flows
- Code change → production (with timings measured in Lab 06).
- Incident detection → alert → runbook → rollback.
- Disaster recovery (measured RTO / RPO from `evidence/dr-drill-*.log`).

## 4. Security controls
- Table: layer → control → tool (gitleaks, semgrep, trivy, cosign, Kyverno, PSA, NetworkPolicy, Sealed Secrets, IMDSv2, SSM instead of SSH).

## 5. SLOs & observability
- SLI/SLO definitions, alert policy, dashboards.

## 6. Cost
- Hourly cost per component on Learner Lab and how it could be reduced.

## 7. Known limitations & next steps
- Link to ADRs.
