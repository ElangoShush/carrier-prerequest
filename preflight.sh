#!/usr/bin/env bash
# preflight.sh — VM/Kubernetes pre-request checks
# Usage: sudo ./preflight.sh [--quick]
set -Eeuo pipefail

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

LOG="/tmp/preflight_$(hostname)_$(date +%F_%H%M%S).txt"
exec > >(tee -a "$LOG") 2>&1

section() { echo -e "\n### $*"; }
kv() { printf "  - %-28s : %s\n" "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
svc_active() { systemctl is-active --quiet "$1" && echo "active" || echo "inactive"; }

START_TS=$(date -Is)

section "1) Host & OS"
OS_NAME="$(. /etc/os-release && echo "$PRETTY_NAME")"
kv "Hostname"           "$(hostname -f 2>/dev/null || hostname)"
kv "OS"                 "$OS_NAME"
kv "Kernel"             "$(uname -r)"
kv "Architecture"       "$(uname -m)"
kv "Uptime"             "$(uptime -p || true)"
kv "SELinux"            "$(getenforce 2>/dev/null || echo 'N/A')"
kv "Firewall (firewalld)" "$(svc_active firewalld)"
kv "Timezone"           "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'N/A')"
kv "NTP Sync"           "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'N/A')"

section "2) Hardware"
MEM_GB=$(awk '/MemTotal/ {printf "%.2f", $2/1024/1024}' /proc/meminfo)
kv "CPU(s)"             "$(nproc)"
kv "Memory (GiB)"       "$MEM_GB"
DISK_SUMMARY="$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -e 7,11 | sed 's/^/    /')"
echo "  - Disks & mounts:"
echo "$DISK_SUMMARY"

section "3) Network Interfaces"
have ip || { echo "ip command not found"; exit 1; }
ip -brief address | sed 's/^/    /'
echo
echo "  - Default route(s):"
ip route | sed 's/^/    /'
# Detect default egress and source
if ip route get 8.8.8.8 >/dev/null 2>&1; then
  RGET=$(ip route get 8.8.8.8)
  SRC_IP=$(echo "$RGET" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  DEV_IF=$(echo "$RGET" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  GW_IP=$(echo "$RGET" | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
  kv "Egress interface" "$DEV_IF"
  kv "Source IP"        "$SRC_IP"
  kv "Gateway (route get)" "${GW_IP:-direct}"
fi

section "4) Connectivity checks"
PING_DESTS=("8.8.8.8" "1.1.1.1")
for D in "${PING_DESTS[@]}"; do
  if ping -W1 -c3 "$D" >/dev/null 2>&1; then
    kv "Ping $D" "OK"
  else
    kv "Ping $D" "FAIL"
  fi
done
# DNS resolution test
DNS_TEST_HOST="www.google.com"
if have getent && getent hosts "$DNS_TEST_HOST" >/dev/null 2>&1; then
  kv "DNS resolve $DNS_TEST_HOST" "OK ($(getent hosts $DNS_TEST_HOST | awk '{print $1}' | paste -sd, -))"
else
  kv "DNS resolve $DNS_TEST_HOST" "FAIL"
fi
# HTTP/HTTPS egress
for URL in "http://example.com" "https://example.com"; do
  if have curl && curl -fsSL --max-time 5 -o /dev/null "$URL"; then
    kv "HTTP check $URL" "OK"
  else
    kv "HTTP check $URL" "FAIL (curl not found or blocked)"
  fi
done
# Cloud metadata reachability (often present in clouds)
if ping -W1 -c1 169.254.169.254 >/dev/null 2>&1; then
  kv "Metadata 169.254.169.254" "reachable"
else
  kv "Metadata 169.254.169.254" "unreachable"
fi

section "5) Listening Ports (top 30)"
if have ss; then
  ss -tulpn | head -n 30 | sed 's/^/    /'
else
  echo "    ss not found"
fi

section "6) Package/Tooling snapshot"
PKG_MGR="unknown"
if have dnf; then PKG_MGR="dnf"; elif have yum; then PKG_MGR="yum"; elif have apt; then PKG_MGR="apt"; fi
kv "Package manager" "$PKG_MGR"
# Count installed packages (RPM/DPKG)
if have rpm; then
  kv "Installed packages (rpm -qa)" "$(rpm -qa | wc -l)"
elif have dpkg-query; then
  kv "Installed packages (dpkg)" "$(dpkg-query -f '.' -W 2>/dev/null | wc -c)"
fi
# Important tools presence
TOOLS=(git curl wget tar unzip zip helm kubectl kubeadm k3s rke2 server rke2-agent docker podman containerd crictl nerdctl mysql psql jq)
for t in "${TOOLS[@]}"; do
  case "$t" in
    server|rke2) continue;;
  esac
  have "$t" && kv "tool:$t" "yes" || kv "tool:$t" "no"
done
# Docker/podman services
kv "docker.service" "$(svc_active docker)"
kv "containerd.service" "$(svc_active containerd 2>/dev/null || true)"
kv "crio.service" "$(svc_active crio 2>/dev/null || true)"
kv "podman.socket" "$(svc_active podman.socket 2>/dev/null || true)"

section "7) Kubernetes / K3s / RKE2 detection"
# Try multiple clients to get node info
get_nodes() {
  if have kubectl && kubectl version --client >/dev/null 2>&1; then
    kubectl get nodes -o wide 2>/dev/null && return 0
  fi
  if have k3s; then
    k3s kubectl get nodes -o wide 2>/dev/null && return 0
  fi
  if have rke2 && have kubectl; then
    KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get nodes -o wide 2>/dev/null && return 0
  fi
  return 1
}
# Basic service hints
kv "kubelet.service" "$(svc_active kubelet 2>/dev/null || true)"
kv "k3s.service"     "$(svc_active k3s 2>/dev/null || true)"
kv "rke2-server"     "$(svc_active rke2-server 2>/dev/null || true)"
kv "rke2-agent"      "$(svc_active rke2-agent 2>/dev/null || true)"

if get_nodes; then
  echo "    Nodes:"
  get_nodes | sed 's/^/      /'
  echo
  echo "    Roles from labels:"
  # Show role labels/taints if kubectl works
  if have kubectl; then
    kubectl get nodes -o json 2>/dev/null | \
      jq -r '.items[] | [.metadata.name,
                         (.metadata.labels["node-role.kubernetes.io/control-plane"] // "no"),
                         (.metadata.labels["node-role.kubernetes.io/master"] // "no"),
                         (.spec.taints // [])] | @tsv' 2>/dev/null | \
      awk -F'\t' 'BEGIN{printf "      %-30s %-10s %-10s %s\n","NODE","ctrl-plane","master","taints"} {printf "      %-30s %-10s %-10s %s\n",$1,$2,$3,$4}'
  fi
else
  echo "    Could not query cluster (no kubeconfig or tools)."
  # Try local hints for control-plane
  ps -ef | grep -E 'kube-apiserver|etcd|rke2|k3s' | grep -v grep | sed 's/^/      /' || true
fi

section "8) Routing sanity"
# Show per-interface routes summary
ip -o route show | awk '{print "    "$0}'
if [[ $QUICK -eq 0 ]]; then
  echo
  echo "    Traceroute to 8.8.8.8 (if available):"
  if have traceroute; then traceroute -n -w 1 -q 1 8.8.8.8 | sed 's/^/      /'; else echo "      traceroute not installed"; fi
fi

section "9) Suggested commands for support (copy/paste)"
echo "    ip -brief address"
echo "    ip route get 8.8.8.8"
echo "    ping -I <iface> -c 3 <gateway>"
echo "    curl -fsS -I https://k8s.io"
echo "    kubectl get nodes -o wide (if kubeconfig present)"
echo "    journalctl -u kubelet -n 200 --no-pager"

section "10) Finish"
kv "Report file" "$LOG"
kv "Start time" "$START_TS"
kv "End time"   "$(date -Is)"

section "11) Upload to GCS"

BUCKET="gs://dito-preflight"
KEY_PATH="/tmp/dito-bucket-sa-key.json"

# Verify key exists
if [ ! -f "$KEY_PATH" ]; then
  echo "  - ERROR: Service account key not found at $KEY_PATH"
  echo "    Please copy dito-bucket-sa-key.json to $KEY_PATH"
  exit 1
fi

# Set credentials for gsutil
export GOOGLE_APPLICATION_CREDENTIALS="$KEY_PATH"

# Ensure gsutil is installed
if ! command -v gsutil >/dev/null 2>&1; then
  echo "  - Installing Google Cloud CLI (for gsutil)"
  tee /etc/yum.repos.d/google-cloud-sdk.repo >/dev/null <<'EOF'
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
  dnf install -y -q google-cloud-cli
fi

# Upload the report file
if [ -f "$LOG" ]; then
  echo "  - Uploading report to $BUCKET"
  gsutil cp "$LOG" "$BUCKET/"
  if [ $? -eq 0 ]; then
    echo "  - Uploaded successfully."
    echo "  - Public URL: https://storage.googleapis.com/dito-preflight/$(basename "$LOG")"
  else
    echo "  - Upload failed."
  fi
else
  echo "  - ERROR: Report file not found ($LOG)"
fi


# Optional: emit a tiny JSON summary if jq is present
if have jq; then
  JSON=$(jq -n \
    --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg os "$OS_NAME" \
    --arg kernel "$(uname -r)" \
    --arg src_ip "${SRC_IP:-}" \
    --arg dev_if "${DEV_IF:-}" \
    --arg gw_ip  "${GW_IP:-}" \
    '{host:$host,os:$os,kernel:$kernel,network:{source_ip:$src_ip,egress_if:$dev_if,gateway:$gw_ip}}')
  section "JSON summary (compact)"
  echo "    $JSON"
fi
