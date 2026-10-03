#!/usr/bin/env bash
# Kiểm tra NetworkPolicy bằng pod thử nghiệm. In OK/BLOCKED cho từng luồng.
#   ./tests/netpol-test.sh shop-dev
NS="${1:-shop-dev}"
probe() {  # probe <pod-label> <host> <port>
  local labels="$1" host="$2" port="$3"
  kubectl -n "$NS" run "np-$RANDOM" --rm -i --restart=Never --quiet \
    --image=busybox:1.36 --labels="$labels" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c","nc -z -w 3 '"$host"' '"$port"' && echo OK || echo BLOCKED"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    2>/dev/null | tail -1
}
printf '%-48s %s\n' "pod lạ → postgres:5432"              "$(probe app=intruder postgres 5432)"
printf '%-48s %s\n' "pod lạ → redis:6379"                 "$(probe app=intruder redis 6379)"
printf '%-48s %s\n' "pod mang nhãn api → postgres:5432"    "$(probe app.kubernetes.io/component=api postgres 5432)"
printf '%-48s %s\n' "pod mang nhãn api → redis:6379"       "$(probe app.kubernetes.io/component=api redis 6379)"
printf '%-48s %s\n' "pod mang nhãn api → 1.1.1.1:443 (internet)" "$(probe app.kubernetes.io/component=api 1.1.1.1 443)"
