#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"

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

if ! command -v whiptail >/dev/null 2>&1; then
  warn "whiptail is not installed on Proxmox host."
  echo "Install: apt update && apt install -y whiptail"
  exit 1
fi

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
  qm  status "$id" >/dev/null 2>&1 && return 1
  return 0
}

# ---------------- Helpers: Debian 12 template ----------------
get_latest_debian12_template() {
  pveam update >/dev/null
  local t
  t="$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$' \
      | sort -V \
      | tail -n 1 || true)"
  [[ -z "${t}" ]] && return 1
  echo "${t}"
}

# ---------------- Defaults ----------------
DEF_HOSTNAME="romm"
DEF_BRIDGE="vmbr0"
DEF_CORES="2"
DEF_MEM="4096"
DEF_SWAP="512"
DEF_DISK="20"
DEF_STORAGE="local-lvm"

# RomM service defaults
DEF_ROMM_PORT="8081"    # external port on LXC IP (internal is 8080)
DEF_DB_NAME="romm"
DEF_DB_USER="romm-user"

msg "Running script version: ${SCRIPT_VERSION}"

# ---------------- Detect template storage (vztmpl) ----------------
TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
[[ -z "${TEMPLATE_STORE}" ]] && die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local)."

# ---------------- Detect latest Debian 12 template ----------------
msg "Detecting latest Debian 12 LXC template..."
TEMPLATE_NAME="$(get_latest_debian12_template || true)"
[[ -z "${TEMPLATE_NAME:-}" ]] && die "No Debian 12 template found. Try: pveam update; pveam available --section system | grep debian-12"
msg "Selected template: ${TEMPLATE_NAME}"

# ---------------- Menus ----------------
CTID_MODE=$(whiptail --title "RomM LXC" --menu "CTID selection:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recommended)" \
  "manual" "Manually enter CTID" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "RomM LXC" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi

[[ ! "${CTID}" =~ ^[0-9]+$ ]] && die "Invalid CTID: ${CTID}"
is_vmid_free "${CTID}" || die "CTID/VMID ${CTID} already exists."
msg "Using CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "RomM LXC" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
BRIDGE=$(whiptail --title "Network" --inputbox "Bridge (e.g. vmbr0):" 10 70 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 1

CORES=$(whiptail --title "Resources" --inputbox "CPU cores:" 10 70 "$DEF_CORES" 3>&1 1>&2 2>&3) || exit 1
MEM=$(whiptail --title "Resources" --inputbox "RAM (MB):" 10 70 "$DEF_MEM" 3>&1 1>&2 2>&3) || exit 1
SWAP=$(whiptail --title "Resources" --inputbox "SWAP (MB):" 10 70 "$DEF_SWAP" 3>&1 1>&2 2>&3) || exit 1
DISK=$(whiptail --title "Resources" --inputbox "Disk (GB):" 10 70 "$DEF_DISK" 3>&1 1>&2 2>&3) || exit 1
STORAGE=$(whiptail --title "Storage" --inputbox "Storage ID for rootfs (e.g. local-lvm/local):" 10 70 "$DEF_STORAGE" 3>&1 1>&2 2>&3) || exit 1

NETMODE=$(whiptail --title "Network" --menu "IP configuration:" 12 70 2 \
  "dhcp"   "Use DHCP (default)" \
  "static" "Use Static IP" \
  3>&1 1>&2 2>&3) || exit 1

IPCFG="dhcp"
GW=""
DEF_IP="192.168.1.60/24"
DEF_GW="192.168.1.1"
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR:" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway:" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

PRIVMODE=$(whiptail --title "Container security" --menu "Container type (Docker compatibility):" 12 80 2 \
  "privileged"   "Privileged (recommended for Docker compatibility)" \
  "unprivileged" "Unprivileged (more secure, may need extra tweaks)" \
  3>&1 1>&2 2>&3) || exit 1

ROMM_PORT=$(whiptail --title "RomM" --inputbox "Expose RomM on this port (external):" 10 70 "$DEF_ROMM_PORT" 3>&1 1>&2 2>&3) || exit 1

DB_ROOT_PASS=$(whiptail --title "MariaDB" --passwordbox "MariaDB root password (leave empty to auto-generate):" 10 70 3>&1 1>&2 2>&3) || exit 1
DB_PASS=$(whiptail --title "MariaDB" --passwordbox "RomM DB user password (leave empty to auto-generate):" 10 70 3>&1 1>&2 2>&3) || exit 1

# ---------------- Ensure template downloaded ----------------
msg "Checking Debian LXC template in '${TEMPLATE_STORE}'..."
if ! pveam list "${TEMPLATE_STORE}" | awk '{print $1}' | grep -q "${TEMPLATE_NAME}"; then
  msg "Template not found locally. Downloading: ${TEMPLATE_NAME}"
  pveam download "${TEMPLATE_STORE}" "${TEMPLATE_NAME}"
else
  msg "Template already present: ${TEMPLATE_NAME}"
fi

# ---------------- Create CT ----------------
msg "Creating LXC ${CTID} (${HOSTNAME})..."
NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
[[ "$IPCFG" != "dhcp" && -n "$GW" ]] && NETCFG="${NETCFG},gw=${GW}"

CREATE_ARGS=(
  "${CTID}" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE_NAME}"
  --hostname "${HOSTNAME}"
  --cores "${CORES}"
  --memory "${MEM}"
  --swap "${SWAP}"
  --rootfs "${STORAGE}:${DISK}"
  --net0 "${NETCFG}"
  --features nesting=1,keyctl=1
  --onboot 1
  --start 1
)

if [[ "${PRIVMODE}" == "unprivileged" ]]; then
  CREATE_ARGS+=( --unprivileged 1 )
fi

pct create "${CREATE_ARGS[@]}"

# ---------------- Install Docker & deploy RomM ----------------
msg "Installing Docker + Compose inside the container..."
pct exec "${CTID}" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "apt-get -y install ca-certificates curl openssl docker.io docker-compose-plugin"

pct exec "${CTID}" -- bash -lc "systemctl enable --now docker"

# Generate secrets if empty (RomM recommends openssl rand -hex 32 for auth key) [1](https://docs.romm.app/4.5.0/Getting-Started/Quick-Start-Guide/)
AUTH_KEY="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 32')"
if [[ -z "${DB_ROOT_PASS}" ]]; then
  DB_ROOT_PASS="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 16')"
fi
if [[ -z "${DB_PASS}" ]]; then
  DB_PASS="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 16')"
fi

msg "Writing RomM docker-compose stack to /opt/romm ..."
pct exec "${CTID}" -- bash -lc "mkdir -p /opt/romm/{library,assets,config,resources,redis-data,mysql_data}"

# Compose based on official example (env vars, volumes, ports, mariadb healthcheck) [2](https://github.com/rommapp/romm/blob/master/examples/docker-compose.example.yml)
pct exec "${CTID}" -- bash -lc "cat > /opt/romm/docker-compose.yml <<'EOF'
version: \"3\"
services:
  romm:
    image: rommapp/romm:latest
    container_name: romm
    restart: unless-stopped
    environment:
      - DB_HOST=romm-db
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWD=${DB_PASSWD}
      - ROMM_AUTH_SECRET_KEY=${ROMM_AUTH_SECRET_KEY}
    volumes:
      - ./resources:/romm/resources
      - ./redis-data:/redis-data
      - ./library:/romm/library
      - ./assets:/romm/assets
      - ./config:/romm/config
    ports:
      - \"${ROMM_PORT}:8080\"
    depends_on:
      romm-db:
        condition: service_healthy
        restart: true

  romm-db:
    image: mariadb:latest
    container_name: romm-db
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
      - MARIADB_DATABASE=${DB_NAME}
      - MARIADB_USER=${DB_USER}
      - MARIADB_PASSWORD=${DB_PASSWD}
    volumes:
      - ./mysql_data:/var/lib/mysql
    healthcheck:
      test: [\"CMD\", \"healthcheck.sh\", \"--connect\", \"--innodb_initialized\"]
      start_period: 30s
      start_interval: 10s
      interval: 10s
      timeout: 5s
      retries: 5
EOF"

pct exec "${CTID}" -- bash -lc "cat > /opt/romm/.env <<EOF
DB_NAME=${DEF_DB_NAME}
DB_USER=${DEF_DB_USER}
DB_PASSWD=${DB_PASS}
DB_ROOT_PASSWORD=${DB_ROOT_PASS}
ROMM_AUTH_SECRET_KEY=${AUTH_KEY}
ROMM_PORT=${ROMM_PORT}
EOF"

msg "Starting RomM with docker compose..."
pct exec "${CTID}" -- bash -lc "cd /opt/romm && docker compose up -d"

CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"

msg "Done ✅"
echo "RomM URL: http://${CTIP:-<CT_IP>}:${ROMM_PORT}"
echo "CTID/VMID: ${CTID}"
echo "Config folder inside CT: /opt/romm/config (optional config.yml recommended) [1](https://docs.romm.app/4.5.0/Getting-Started/Quick-Start-Guide/)"
echo "Library folder inside CT: /opt/romm/library (ROMs must follow RomM folder structure) [1](https://docs.romm.app/4.5.0/Getting-Started/Quick-Start-Guide/)"
echo
echo "Saved secrets in: /opt/romm/.env"
echo "DB_USER=${DEF_DB_USER}"
echo "DB_PASSWD=${DB_PASS}"
echo "DB_ROOT_PASSWORD=${DB_ROOT_PASS}"
echo "ROMM_AUTH_SECRET_KEY=${AUTH_KEY}"
echo
echo "Security tip: restrict ${ROMM_PORT}/tcp via Proxmox firewall to LAN/VPN only."
