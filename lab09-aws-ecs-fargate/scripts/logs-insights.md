# Truy vấn CloudWatch Logs Insights cho shopmini (log group /ecs/shop-lab09)

```
# 1. Request chậm nhất 15 phút qua
fields @timestamp, method, path, status, duration_ms, request_id
| filter ispresent(duration_ms)
| sort duration_ms desc
| limit 20

# 2. Tỷ lệ lỗi theo phút
filter ispresent(status)
| stats count(*) as total, sum(status >= 500) as errors by bin(1m)
| sort @timestamp desc

# 3. Lần theo một request cụ thể qua mọi task
fields @timestamp, @logStream, msg, status
| filter request_id = "<dán request id từ header x-request-id>"

# 4. p95 latency theo route (TODO: tự viết – gợi ý: pct(duration_ms, 95))
```
