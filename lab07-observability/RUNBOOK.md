# Runbook – shopmini

> Mỗi alert phải có một mục ở đây. Người trực đọc runbook **trước** khi hành động.
> TODO (Bài 6): hoàn thiện các mục còn trống dựa trên kinh nghiệm thực tế khi làm lab.

## ErrorBudgetBurn
**Ý nghĩa:** tỷ lệ lỗi 5xx vượt ngưỡng burn-rate (fast = gọi người trực; slow = ticket).

**Kiểm tra nhanh (5 phút đầu):**
1. Dashboard *shopmini – RED & SLO*: lỗi tập trung ở route nào, status nào? Bắt đầu từ lúc nào?
2. Có deploy mới không? `argocd app history shopmini-<env>` / `kubectl argo rollouts get rollout shopmini -n shop-prod`
3. Log lỗi: Grafana → Explore → Loki: `{namespace="shop-dev", app="shopmini"} | json | level="ERROR"`
4. Phụ thuộc: `kubectl -n <ns> exec deploy/shopmini -- python -c "...readyz..."` (DB? Redis?)

**Giảm thiểu:** nếu trùng thời điểm deploy → rollback bằng `git revert` (GitOps). Nếu do DB → …(TODO)

**Sau sự cố:** viết postmortem (template ở cuối file).

## HighLatencyP95
TODO

## NoTraffic
TODO

---
### Template postmortem (blameless)
- **Tóm tắt** (1–2 câu):
- **Ảnh hưởng**: thời gian, % request lỗi, budget đã tiêu:
- **Timeline** (giờ – sự kiện):
- **Nguyên nhân gốc** (5 Whys):
- **Điều gì làm tốt / chưa tốt**:
- **Action items** (người phụ trách, hạn):
