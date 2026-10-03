# Lab 03 – Ansible: cấu hình, hardening và rolling update cho cả fleet

> **Thời lượng:** 4–5 giờ · **Chạy ở:** Local (2 container) → Learner Lab (3 EC2) · **Chi phí:** ~0,03 USD/giờ (3×t3.micro)

## 🎯 Target

| # | Target | Cách đo |
|---|---|---|
| T1 | `ansible-lint --profile production` **đạt** | `verify.sh` |
| T2 | **Idempotent**: chạy `site.yml` lần 2 → `changed=0 failed=0` trên mọi host | `verify.sh` |
| T3 | Hardening: `PasswordAuthentication no`, `PermitRootLogin no`, sysctl CIS cơ bản, user `deploy` có sudo được kiểm tra bằng `visudo` | `verify.sh` |
| T4 | Dynamic inventory: **không ghi IP tay**, host tự nhóm theo tag `Role`/`Os` | `ansible-inventory --graph` |
| T5 | node_exporter (:9100) và app (:8080) chạy trên cả 3 EC2, **cùng một playbook** cho Ubuntu và Amazon Linux | `TARGET=aws ./verify.sh` |
| T6 | Rolling update `serial: 1`: một host hỏng thì **dừng ngay**, các host còn lại giữ bản cũ | Bài 4 |
| T7 | Secret của app mã hóa bằng **ansible-vault**, gitleaks sạch | `verify.sh` |

## Kiến trúc

```
   Control node (WSL2)                         Learner Lab – default VPC
 ┌──────────────────────┐   SSH (vockey)   ┌───────────┐ ┌───────────┐ ┌────────────┐
 │ ansible-playbook     │ ───────────────▶ │ web-1     │ │ web-2     │ │ web-3      │
 │  ├ inventories/aws   │                  │ Ubuntu24  │ │ Ubuntu24  │ │ AL2023     │
 │  │  (aws_ec2 plugin) │                  │ :9100 :8080│ │ :9100 :8080│ │ :9100 :8080│
 │  └ roles/            │                  └───────────┘ └───────────┘ └────────────┘
 │     common hardening │
 │     node_exporter    │   Local: plugin "docker" → 2 container (ubuntu:24.04, amazonlinux:2023)
 │     docker app       │
 └──────────────────────┘
```

## Kiến thức nền

- **Idempotent** nghĩa là chạy N lần cũng cho kết quả như chạy 1 lần. Module (`apt`, `template`, `user`…) đã idempotent sẵn. Còn `command`/`shell` thì **không**, nên phải dùng `creates`, `changed_when` hoặc `when` để kiểm soát.
- **Handler** chỉ chạy khi có task `notify` báo thay đổi, và chạy **một lần** vào cuối play. Ví dụ: đổi cấu hình sshd thì mới reload sshd.
- **`validate:`** trong `template`/`copy` kiểm tra file **trước khi** ghi đè. Viết sai cú pháp sudoers hay sshd mà không có `validate` là có thể tự khóa mình ra khỏi server.
- **Thứ tự ưu tiên biến:** `role defaults` < `group_vars` < `host_vars` < `-e` (extra vars). Đây là câu phỏng vấn rất hay gặp.

---

## Bài 1 – Luyện trên container local

```bash
cd lab03-ansible
ansible-galaxy collection install -r requirements.yml
./scripts/local-targets.sh up
ansible all -m ansible.builtin.ping
ansible all -m ansible.builtin.setup -a 'filter=ansible_distribution*'
ansible-playbook site.yml --check --diff      # dry-run: xem sẽ thay đổi gì
ansible-playbook site.yml
ansible-playbook site.yml                     # lần 2: changed phải = 0
```

Một số task được bỏ qua trong container (systemd, sysctl kernel, docker) nhờ biến `is_container`. **TODO:** liệt kê các task bị skip và giải thích vì sao container không làm được việc đó.

## Bài 2 – Fleet thật trên Learner Lab

```bash
export AWS_PROFILE=academy
# Learner Lab → AWS Details → Download PEM → lưu ~/.ssh/labsuser.pem
chmod 600 ~/.ssh/labsuser.pem
cd terraform && terraform init && terraform apply -var my_ip="$(curl -s https://checkip.amazonaws.com)/32" && cd ..
ansible-inventory -i inventories/aws/aws_ec2.yml --graph     # thấy group role_web, os_ubuntu, os_al2023
ansible -i inventories/aws/aws_ec2.yml all -m ansible.builtin.ping
ansible-playbook -i inventories/aws/aws_ec2.yml site.yml
curl -s http://<ip-web-1>:9100/metrics | grep node_load1
curl -s http://<ip-web-1>:8080/healthz
```

## Bài 3 – Viết thêm role (bắt buộc)

**TODO:** tạo role `roles/firewall`:

- Ubuntu dùng `ufw`, Amazon Linux dùng `firewalld`. Chọn bằng `include_tasks: "{{ ansible_os_family | lower }}.yml"` (giống role `common`).
- Chặn mặc định mọi inbound, chỉ mở `22`, `{{ node_exporter_port }}`, `{{ app_port }}`. Port lấy từ biến, không hard-code.
- **Không được tự khóa mình**: mở port 22 **trước** khi bật default deny.
- Chạy 2 lần phải idempotent. Thêm role vào play đầu của `site.yml` với tag `firewall`.

<details><summary>Gợi ý cho Ubuntu</summary>

```yaml
- name: Cho phép các port cần thiết
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
  loop: ["{{ sshd_port }}", "{{ node_exporter_port }}", "{{ app_port }}"]
- name: Default deny incoming + bật ufw
  community.general.ufw:
    state: enabled
    direction: incoming
    policy: deny
```
</details>

## Bài 4 – Rolling update có kiểm soát

```bash
# Bản tốt
ansible-playbook -i inventories/aws/aws_ec2.yml rolling-update.yml -e app_image=ghcr.io/stefanprodan/podinfo:6.7.0
# Bản "hỏng": image không tồn tại → host đầu tiên fail → play DỪNG, web-2 và web-3 giữ bản cũ
ansible-playbook -i inventories/aws/aws_ec2.yml rolling-update.yml -e app_image=ghcr.io/stefanprodan/podinfo:0.0.0-broken
```

**TODO:**
1. Chứng minh web-2 và web-3 vẫn chạy bản cũ sau lần deploy hỏng (`docker inspect` qua ad-hoc command).
2. Đổi `serial` thành `[1, "50%"]` (canary 1 máy rồi 50%), chạy lại, giải thích thứ tự.
3. Viết thêm `rollback.yml` triển khai lại image trước đó. Lưu tag "last known good" vào file fact `/etc/ansible/facts.d/app.fact` trên mỗi host.

## Bài 5 – Secret với ansible-vault

```bash
ansible-vault create group_vars/vault.yml       # nội dung: vault_app_secret: "s3cr3t-value"
echo 'my-vault-pass' > ~/.vault_pass && chmod 600 ~/.vault_pass   # KHÔNG commit file này
```

**TODO:** đưa `APP_SECRET: "{{ vault_app_secret }}"` vào `app_env`, chạy playbook với `--vault-password-file ~/.vault_pass`, thêm `no_log: true` cho task in ra env. Đảm bảo `gitleaks dir .` không còn phát hiện gì.

## Bài 6 – Chấm điểm

```bash
./verify.sh                 # local
TARGET=aws ./verify.sh      # fleet AWS
```

---

## 🔥 Sự cố cố ý (break-fix)

| # | Cách gây lỗi | Việc của bạn |
|---|---|---|
| B1 | Thêm vào template sshd dòng `PermitRootLogin maybe` | `validate: sshd -t` chặn lại, server vẫn an toàn. Thử bỏ `validate` (trên container!) để thấy hậu quả |
| B2 | Thay task tạo host key bằng `command: ssh-keygen -A` **không có** `creates:` | Lần chạy 2 vẫn báo `changed` → T2 FAIL. Sửa bằng `creates`/`changed_when` |
| B3 | Đặt `node_exporter_version: "1.8.2"` trong `-e` nhưng sửa `group_vars` thành `1.7.0` | Bản nào được cài? Vì sao? (thứ tự ưu tiên biến) |
| B4 | Xóa dòng `ansible_user: ec2-user` trong `os_al2023.yml` | `UNREACHABLE` trên web-3. Đọc output `-vvv` để tìm nguyên nhân |
| B5 | Trên web-1, sửa tay `/etc/ssh/sshd_config.d/10-hardening.conf` | Chạy `--check --diff` để phát hiện drift, rồi chạy thật để đưa về trạng thái chuẩn |
| B6 | Đổi SG để chặn port 22 từ IP của bạn | Phân biệt `UNREACHABLE` với `FAILED`. Gợi ý: Ansible chạy qua **SSM** bằng connection plugin `amazon.aws.aws_ssm` để không cần port 22 |

## 🚀 Thử thách mở rộng

- Dùng **Molecule** + driver docker để test role `hardening` tự động trong CI.
- So sánh role `hardening` tự viết với [dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening), rồi chạy **Lynis** (`lynis audit system`) trước và sau khi hardening để so điểm.
- Chạy Ansible qua **Session Manager** (connection `amazon.aws.aws_ssm`) và đóng port 22 hoàn toàn.

## 🧹 Cleanup

```bash
./scripts/local-targets.sh down
cd terraform && terraform destroy -var my_ip=0.0.0.0/32
```

## ❓ Câu hỏi tự kiểm tra

1. Ansible khác Terraform ở điểm nào? Khi nào dùng cả hai cùng nhau?
2. `include_tasks` và `import_tasks` khác nhau thế nào (static/dynamic)?
3. `serial`, `max_fail_percentage`, `any_errors_fatal` phối hợp ra sao trong rolling update?
4. Vì sao nên dùng `ansible.builtin.command` kèm `creates:` thay vì `shell`?
5. Pull-based (ansible-pull, GitOps) khác push-based (ansible-playbook từ control node) thế nào?

## Tham khảo

- [dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening)
- [geerlingguy/ansible-role-docker](https://github.com/geerlingguy/ansible-role-docker): role cộng đồng chuẩn mực, nên đọc để học cách viết role đa nền tảng
- [prometheus/node_exporter](https://github.com/prometheus/node_exporter)
