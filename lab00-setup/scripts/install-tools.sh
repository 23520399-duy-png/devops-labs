#!/usr/bin/env bash
# Cài bộ công cụ DevOps cho Ubuntu (WSL2) – idempotent: chạy lại nhiều lần không sao.
# Dùng:  ./install-tools.sh            # cài những gì còn thiếu
#        FORCE=1 ./install-tools.sh    # cài lại tất cả (cập nhật bản mới)
set -euo pipefail

ARCH="$(dpkg --print-architecture)"            # amd64 | arm64
BIN="/usr/local/bin"
FORCE="${FORCE:-0}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
have() { [ "$FORCE" = "0" ] && command -v "$1" >/dev/null 2>&1; }
latest_tag() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }
install_bin() { sudo install -m 0755 "$1" "$BIN/$2"; }

log "Gói hệ thống cơ bản"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl wget unzip gnupg lsb-release jq git make tree htop \
  dnsutils net-tools iproute2 netcat-openbsd tcpdump bash-completion \
  python3 python3-venv python3-pip pipx shellcheck

# ---------------------------------------------------------------- AWS
if ! have aws; then
  log "AWS CLI v2"
  awsarch=$([ "$ARCH" = "arm64" ] && echo aarch64 || echo x86_64)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}.zip" -o "$TMP/awscli.zip"
  unzip -q "$TMP/awscli.zip" -d "$TMP" && sudo "$TMP/aws/install" --update
fi
if ! have session-manager-plugin; then
  log "Session Manager plugin (để 'aws ssm start-session')"
  smarch=$([ "$ARCH" = "arm64" ] && echo ubuntu_arm64 || echo ubuntu_64bit)
  curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${smarch}/session-manager-plugin.deb" -o "$TMP/smp.deb"
  sudo dpkg -i "$TMP/smp.deb"
fi

# ---------------------------------------------------------------- Terraform (HashiCorp apt repo)
if ! have terraform; then
  log "Terraform"
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y terraform
fi
if ! have tflint; then
  log "tflint"
  curl -fsSL "https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_${ARCH}.zip" -o "$TMP/tflint.zip"
  unzip -o -q "$TMP/tflint.zip" -d "$TMP" && install_bin "$TMP/tflint" tflint
fi

# ---------------------------------------------------------------- Kubernetes
if ! have kubectl; then
  log "kubectl"
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}/kubectl" -o "$TMP/kubectl"
  install_bin "$TMP/kubectl" kubectl
fi
if ! have kind; then
  log "kind"
  curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}" -o "$TMP/kind"
  install_bin "$TMP/kind" kind
fi
if ! have helm; then
  log "helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
if ! have k9s; then
  log "k9s"
  curl -fsSL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH}.tar.gz" | tar -xz -C "$TMP" k9s
  install_bin "$TMP/k9s" k9s
fi
if ! have kustomize; then
  log "kustomize"
  (cd "$TMP" && curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash)
  install_bin "$TMP/kustomize" kustomize
fi
if ! have argocd; then
  log "argocd CLI"
  curl -fsSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}" -o "$TMP/argocd"
  install_bin "$TMP/argocd" argocd
fi
if ! have kubectl-argo-rollouts; then
  log "kubectl argo rollouts plugin"
  curl -fsSL "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-${ARCH}" -o "$TMP/kar"
  install_bin "$TMP/kar" kubectl-argo-rollouts
fi
if ! have kubeseal; then
  log "kubeseal"
  tag="$(latest_tag bitnami-labs/sealed-secrets)"; v="${tag#v}"
  curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/${tag}/kubeseal-${v}-linux-${ARCH}.tar.gz" | tar -xz -C "$TMP" kubeseal
  install_bin "$TMP/kubeseal" kubeseal
fi
if ! have kyverno; then
  log "kyverno CLI"
  tag="$(latest_tag kyverno/kyverno)"; karch=$([ "$ARCH" = "arm64" ] && echo arm64 || echo x86_64)
  curl -fsSL "https://github.com/kyverno/kyverno/releases/download/${tag}/kyverno-cli_${tag}_linux_${karch}.tar.gz" | tar -xz -C "$TMP" kyverno
  install_bin "$TMP/kyverno" kyverno
fi

# ---------------------------------------------------------------- Security & quality
if ! have trivy; then
  log "trivy"
  curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b "$BIN"
fi
if ! have gitleaks; then
  log "gitleaks"
  tag="$(latest_tag gitleaks/gitleaks)"; v="${tag#v}"; garch=$([ "$ARCH" = "arm64" ] && echo arm64 || echo x64)
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/${tag}/gitleaks_${v}_linux_${garch}.tar.gz" | tar -xz -C "$TMP" gitleaks
  install_bin "$TMP/gitleaks" gitleaks
fi
if ! have cosign; then
  log "cosign"
  curl -fsSL "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${ARCH}" -o "$TMP/cosign"
  install_bin "$TMP/cosign" cosign
fi
if ! have yq; then
  log "yq"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" -o "$TMP/yq"
  install_bin "$TMP/yq" yq
fi
if ! have k6; then
  log "k6 (load testing)"
  tag="$(latest_tag grafana/k6)"
  curl -fsSL "https://github.com/grafana/k6/releases/download/${tag}/k6-${tag}-linux-${ARCH}.tar.gz" | tar -xz -C "$TMP"
  install_bin "$TMP/k6-${tag}-linux-${ARCH}/k6" k6
fi
if ! have act; then
  log "act (chạy GitHub Actions local)"
  curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- -b "$BIN"
fi

# ---------------------------------------------------------------- Python tools (pipx: mỗi tool một venv riêng)
pipx ensurepath >/dev/null
for pkg in ansible-core ansible-lint pre-commit checkov yamllint; do
  cmd="$pkg"; [ "$pkg" = "ansible-core" ] && cmd="ansible"
  if ! have "$cmd"; then log "pipx install $pkg"; pipx install --force "$pkg"; fi
done
pipx inject ansible-core boto3 botocore >/dev/null 2>&1 || true   # cho dynamic inventory aws_ec2

# ---------------------------------------------------------------- Docker
if ! command -v docker >/dev/null 2>&1; then
  cat <<'MSG'

[!] Chưa có Docker. Chọn MỘT trong hai cách:
    (1) Khuyến nghị: cài Docker Desktop trên Windows → Settings → Resources → WSL integration → bật cho Ubuntu.
    (2) Cài Docker Engine trực tiếp trong WSL2:
        curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker "$USER"
        (bật systemd trong /etc/wsl.conf: [boot] systemd=true, rồi 'wsl --shutdown' từ PowerShell)
MSG
fi

log "Xong. Mở terminal mới (hoặc 'source ~/.bashrc') rồi chạy: ./check-env.sh"
