# ADR-0001: Dùng k3s trên EC2 thay vì Amazon EKS

- **Trạng thái:** Chấp nhận
- **Ngày:** 2026-10-03

## Bối cảnh
Capstone cần Kubernetes thật trên AWS để chạy GitOps. Môi trường là AWS Academy Learner Lab: không tạo được IAM role tùy ý, giới hạn instance ≤ large, credit có hạn, phiên lab tự dừng EC2.

## Các lựa chọn đã cân nhắc
1. **EKS**: managed control plane (~0,10 USD/giờ) + node group. Ưu: giống production. Nhược: phụ thuộc quyền IAM của Learner Lab (role cluster/node, OIDC cho IRSA), tốn credit.
2. **k3s trên EC2**: Ưu: rẻ, nhanh, toàn quyền kiểm soát, học được bootstrap cluster. Nhược: control plane single-node (SPOF), tự vận hành nâng cấp.
3. **kind local**: không phải hạ tầng cloud thật.

## Quyết định
Chọn k3s (1 server + 2 agent trong ASG). Mọi thứ phía trên cluster dùng chuẩn Kubernetes và GitOps, nên khi chuyển sang EKS chỉ cần thay tầng Terraform.

## Hệ quả
- Server là single point of failure → bù lại bằng DR drill (dựng lại < 30 phút) thay vì HA.
- TODO: ADR tiếp theo đánh giá k3s HA (3 server, embedded etcd) hoặc EKS khi có môi trường phù hợp.
