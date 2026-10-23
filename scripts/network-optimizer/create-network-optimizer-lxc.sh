#!/usr/bin/env bash

# ------------------------------------------------------------
# AUTO-FIX: if this file contains HTML entities (&gt; &lt; &amp; etc),
# unescape and re-run. Prevents "script does nothing" scenarios.
# ------------------------------------------------------------
if grep -qE '&(gt|lt|amp|quot|apos|#39);' "$0" 2>/dev/null; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$0" | bash
import sys, html
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='ignore') as f:
    data = f.read()
print(html.unescape(data))
PY
    exit $?
  else
    sed -e 's/&gt;/>/g' -e 's/&lt;/</g' -e 's/&amp;/\&/g' "$0" | bash
    exit $?
  fi
fi

set -euo pipefail

SCRIPT_VERSION="0.1.0"

# Network Optimizer for UniFi (Ozark Connect) - https://github.com/Ozark-Connect/NetworkOptimizer
# Pinned image version. Override with: NETOPT_VERSION=x.y.z bash create-network-optimizer-lxc.sh
NETOPT_VERSION="${NETOPT_VERSION:-2.10.0}"

msg()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need pct
need pveam
need pvesm
need awk
need grep
need sort
need tail
need tr
need mktemp

if ! command -v whiptail >/dev/null 2>&1; then
  warn "whiptail is not installed on Proxmox host."
  echo "Install: apt update && apt install -y whiptail"
  exit 1
fi

msg "Running script version: ${SCRIPT_VERSION} (Network Optimizer ${NETOPT_VERSION})"

# ---------------- Helpers: CTID/VMID ----------------
get_next_id() {
  if command -v pvesh >/dev/null 2>&1; then
    local nid
    nid="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "${nid}" && "${nid}" =~ ^[0-9]+$ ]]; then
      echo "${nid}"; return 0
    fi
  fi
  local max_id=99 pct_max qm_max
  pct_max="$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
  qm_max="$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
  [[ -n "${pct_max:-}" && "${pct_max}" =~ ^[0-9]+$ ]] && (( pct_max > max_id )) && max_id=$pct_max
  [[ -n "${qm_max:-}" && "${qm_max}" =~ ^[0-9]+$ ]] && (( qm_max > max_id )) && max_id=$qm_max
  echo $((max_id + 1))
}

is_vmid_free() {
  local id="$1"
  pct status "$id" >/dev/null 2>&1 && return 1
  qm status "$id" >/dev/null 2>&1 && return 1
  return 0
}

# ---------------- Helpers: Debian template (13, fallback 12) ----------------
get_latest_debian_template() {
  local ver="$1" t
  t="$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep -E "^debian-${ver}-standard_.*_amd64\.tar\.(zst|xz|gz)$" \
    | sort -V \
    | tail -n 1 || true)"
  [[ -z "${t}" ]] && return 1
  echo "${t}"
}

# ---------------- Defaults ----------------
DEF_HOSTNAME="netopt"
DEF_BRIDGE="vmbr0"
DEF_VLAN="10"
DEF_CORES="2"
DEF_MEM="2048"
DEF_SWAP="512"
DEF_DISK="10"
DEF_STORAGE="local-lvm"
DEF_IP="10.10.10.61/24"
DEF_GW="10.10.10.1"
DEF_DNS="192.168.50.119 192.168.50.120"
DEF_TZ="Europe/Lisbon"

# ---------------- Detect template storage (vztmpl) ----------------
TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
[[ -z "${TEMPLATE_STORE}" ]] && die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local)."

# ---------------- Detect latest Debian template ----------------
msg "Detecting latest Debian LXC template (13, fallback 12)..."
pveam update >/dev/null
TEMPLATE_NAME="$(get_latest_debian_template 13 || get_latest_debian_template 12 || true)"
[[ -z "${TEMPLATE_NAME:-}" ]] && die "No Debian 13/12 template found. Try: pveam update; pveam available --section system | grep debian"
msg "Selected template: ${TEMPLATE_NAME}"

# ---------------- Menus ----------------
TITLE="Network Optimizer LXC"

CTID_MODE=$(whiptail --title "$TITLE" --menu "CTID selection:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recommended)" \
  "manual" "Manually enter CTID" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "$TITLE" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi

[[ ! "${CTID}" =~ ^[0-9]+$ ]] && die "Invalid CTID: ${CTID}"
is_vmid_free "${CTID}" || die "CTID/VMID ${CTID} already exists."
msg "Using CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1

CORES=$(whiptail --title "Resources" --inputbox "CPU cores:" 10 70 "$DEF_CORES" 3>&1 1>&2 2>&3) || exit 1
MEM=$(whiptail --title "Resources" --inputbox "RAM (MB, 2048 minimum):" 10 70 "$DEF_MEM" 3>&1 1>&2 2>&3) || exit 1
SWAP=$(whiptail --title "Resources" --inputbox "SWAP (MB):" 10 70 "$DEF_SWAP" 3>&1 1>&2 2>&3) || exit 1
DISK=$(whiptail --title "Resources" --inputbox "Disk (GB, 10 minimum):" 10 70 "$DEF_DISK" 3>&1 1>&2 2>&3) || exit 1
STORAGE=$(whiptail --title "Storage" --inputbox "Storage ID for rootfs (e.g. local-lvm/local):" 10 70 "$DEF_STORAGE" 3>&1 1>&2 2>&3) || exit 1

BRIDGE=$(whiptail --title "Network" --inputbox "Bridge (e.g. vmbr0):" 10 70 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 1
VLAN=$(whiptail --title "Network" --inputbox "VLAN tag (empty = untagged):" 10 70 "$DEF_VLAN" 3>&1 1>&2 2>&3) || exit 1

NETMODE=$(whiptail --title "Network" --menu "IP configuration:" 12 70 2 \
  "static" "Static IP (recommended: speed test needs a stable HOST_IP)" \
  "dhcp"   "DHCP" \
  3>&1 1>&2 2>&3) || exit 1

IPCFG="dhcp"
GW=""
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR:" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway:" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi
DNS=$(whiptail --title "Network" --inputbox "DNS servers (space separated, empty = host's):" 10 70 "$DEF_DNS" 3>&1 1>&2 2>&3) || exit 1

FEATMODE=$(whiptail --title "Container features" --menu "Unprivileged container features:" 12 80 2 \
  "nesting"        "nesting=1 only (Terraform-compatible, ADR-005)" \
  "nesting-keyctl" "nesting=1,keyctl=1 (fallback if Docker fails)" \
  3>&1 1>&2 2>&3) || exit 1
FEATURES="nesting=1"
[[ "$FEATMODE" == "nesting-keyctl" ]] && FEATURES="nesting=1,keyctl=1"

TZ_VAL=$(whiptail --title "Network Optimizer" --inputbox "Timezone:" 10 70 "$DEF_TZ" 3>&1 1>&2 2>&3) || exit 1

# ---------------- Ensure template downloaded ----------------
msg "Checking Debian LXC template in '${TEMPLATE_STORE}'..."
if ! pveam list "${TEMPLATE_STORE}" | awk '{print $1}' | grep -q "${TEMPLATE_NAME}"; then
  msg "Template not found locally. Downloading: ${TEMPLATE_NAME}"
  pveam download "${TEMPLATE_STORE}" "${TEMPLATE_NAME}"
else
  msg "Template already present: ${TEMPLATE_NAME}"
fi

# ---------------- Create CT ----------------
msg "Creating unprivileged LXC ${CTID} (${HOSTNAME}) with features ${FEATURES}..."
NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
[[ -n "${VLAN}" ]] && NETCFG="${NETCFG},tag=${VLAN}"
[[ "$IPCFG" != "dhcp" && -n "$GW" ]] && NETCFG="${NETCFG},gw=${GW}"

CREATE_ARGS=(
  "${CTID}" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE_NAME}"
  --hostname "${HOSTNAME}"
  --cores "${CORES}"
  --memory "${MEM}"
  --swap "${SWAP}"
  --rootfs "${STORAGE}:${DISK}"
  --net0 "${NETCFG}"
  --unprivileged 1
  --features "${FEATURES}"
  --tags "network;docker"
  --onboot 1
  --start 1
)
[[ -n "${DNS}" ]] && CREATE_ARGS+=( --nameserver "${DNS}" )

pct create "${CREATE_ARGS[@]}"

msg "Waiting for network inside the container..."
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- bash -c "getent hosts deb.debian.org >/dev/null 2>&1"; then
    break
  fi
  [[ $i -eq 30 ]] && die "No DNS/network inside CT ${CTID}. Check bridge/VLAN/gateway/firewall policy."
  sleep 2
done

# ---------------- Install Docker CE + compose plugin (official repo) ----------------
msg "Installing Docker CE + compose plugin from Docker's official repository..."
pct exec "${CTID}" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get -y install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
'

# ---------------- Docker smoke test (the keyctl question) ----------------
msg "Docker smoke test (features: ${FEATURES})..."
if ! pct exec "${CTID}" -- bash -c "docker run --rm hello-world >/dev/null"; then
  die "Docker cannot run containers with features '${FEATURES}'. Re-run with 'nesting-keyctl' or use a VM."
fi
msg "Docker runs containers with features '${FEATURES}' ✅"

# ---------------- Prepare stack files (host) and pct push ----------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

HOST_IP_VAL=""
[[ "$IPCFG" != "dhcp" ]] && HOST_IP_VAL="${IPCFG%%/*}"

cat > "${TMPDIR}/.env" <<EOF
TZ=${TZ_VAL}
NETOPT_VERSION=${NETOPT_VERSION}
HOST_IP=${HOST_IP_VAL}
BIND_LOCALHOST_ONLY=false
IPERF3_SERVER_ENABLED=false
OPENSPEEDTEST_PORT=3005
LOG_LEVEL=Information
APP_LOG_LEVEL=Information
EOF

# Based on upstream docker/docker-compose.prod.yml, with pinned image versions.
cat > "${TMPDIR}/docker-compose.yml" <<'EOF'
services:
  network-optimizer:
    image: ghcr.io/ozark-connect/network-optimizer:${NETOPT_VERSION}
    container_name: network-optimizer
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./data:/app/data
      - ./ssh-keys:/app/ssh-keys
      - ./logs:/app/logs
    environment:
      - TZ=${TZ}
      - BIND_LOCALHOST_ONLY=${BIND_LOCALHOST_ONLY:-false}
      - HOST_IP=${HOST_IP:-}
      - OPENSPEEDTEST_PORT=${OPENSPEEDTEST_PORT:-3005}
      - Iperf3Server__Enabled=${IPERF3_SERVER_ENABLED:-false}
      - Logging__LogLevel__Default=${LOG_LEVEL:-Information}
      - Logging__LogLevel__NetworkOptimizer=${APP_LOG_LEVEL:-Information}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8042/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s

  network-optimizer-speedtest:
    image: ghcr.io/ozark-connect/speedtest:${NETOPT_VERSION}
    container_name: network-optimizer-speedtest
    restart: unless-stopped
    ports:
      - "${OPENSPEEDTEST_PORT:-3005}:3000"
    sysctls:
      net.ipv4.tcp_rmem: "4096 131072 33554432"
      net.ipv4.tcp_wmem: "4096 65536 33554432"
      net.ipv4.tcp_mtu_probing: "1"
    environment:
      - TZ=${TZ}
      - HOST_IP=${HOST_IP:-}
      - OPENSPEEDTEST_PORT=${OPENSPEEDTEST_PORT:-3005}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

msg "Writing stack to /opt/network-optimizer ..."
pct exec "${CTID}" -- bash -c "mkdir -p /opt/network-optimizer/{data,ssh-keys,logs} && chmod 700 /opt/network-optimizer/data"
pct push "${CTID}" "${TMPDIR}/.env" /opt/network-optimizer/.env --perms 0600
pct push "${CTID}" "${TMPDIR}/docker-compose.yml" /opt/network-optimizer/docker-compose.yml --perms 0644

# ---------------- Start stack ----------------
msg "Pulling images (${NETOPT_VERSION}) and starting the stack..."
pct exec "${CTID}" -- bash -c "cd /opt/network-optimizer && docker compose pull && docker compose up -d" \
  || die "Failed to start the stack. Check that tag '${NETOPT_VERSION}' exists on ghcr.io/ozark-connect."

msg "Waiting for network-optimizer to become healthy (up to ~4 min)..."
pct exec "${CTID}" -- bash -c '
for i in $(seq 1 80); do
  status=$(docker inspect -f "{{.State.Health.Status}}" network-optimizer 2>/dev/null || echo "starting")
  if [ "$status" = "healthy" ]; then echo "[+] network-optimizer is healthy"; exit 0; fi
  echo "[*] status: $status (try $i/80)"
  sleep 3
done
echo "[!] network-optimizer did not become healthy in time"
docker logs --tail=80 network-optimizer || true
exit 1
'

CTIP="$(pct exec "${CTID}" -- bash -c "hostname -I | awk '{print \$1}'" || true)"

msg "Done ✅"
echo "Web UI:      http://${CTIP:-<CT_IP>}:8042"
echo "Speed test:  http://${CTIP:-<CT_IP>}:3005"
echo "CTID/VMID:   ${CTID} (features: ${FEATURES})"
echo "Stack path:  /opt/network-optimizer"
echo
echo "Initial admin password (user 'admin'):"
pct exec "${CTID}" -- bash -c "docker logs network-optimizer 2>&1 | grep -A5 'AUTO-GENERATED'" || \
  echo "  pct exec ${CTID} -- docker logs network-optimizer 2>&1 | grep -A5 'AUTO-GENERATED'"
echo
echo "Next steps:"
echo "  - Change the admin password in Settings > Admin Password."
echo "  - UniFi: create a Local Access Only admin with Network = View Only."
echo "  - Update: pct exec ${CTID} -- bash -c 'cd /opt/network-optimizer && sed -i \"s/^NETOPT_VERSION=.*/NETOPT_VERSION=<new>/\" .env && docker compose pull && docker compose up -d && docker image prune -f'"
