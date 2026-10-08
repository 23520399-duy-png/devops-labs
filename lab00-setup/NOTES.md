## Lab 00 – break-fix thực tế
- **Lỗi:** check-env báo FAIL SSH GitHub dù `ssh -T` thành công.
- **Nguyên nhân:** GitHub luôn trả exit code 1 cho `ssh -T`. Khi bật `set -o pipefail`, cả pipeline bị coi là lỗi.
- **Cách sửa:** lưu output vào biến (`|| true`), rồi mới grep chuỗi "successfully authenticated".
- **Bài học:** đừng dựa vào exit code của công cụ mà chưa đọc tài liệu; kiểm tra nội dung output.
- **Lỗi khác:** apt NO_PUBKEY (key repo hết hạn hoặc đổi), sửa bằng cách tải lại key vào đúng keyring `signed-by`.
