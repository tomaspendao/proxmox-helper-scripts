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

SCRIPT_VERSION="1.0.4"

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

msg "Running script version: ${SCRIPT_VERSION}"

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

DEF_ROMM_PORT="8081"        # external port, RomM internal is 8080
DEF_DB_NAME="romm"
DEF_DB_USER="romm-user"

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
DB_NAME=$(whiptail --title "Database" --inputbox "DB name:" 10 70 "$DEF_DB_NAME" 3>&1 1>&2 2>&3) || exit 1
DB_USER=$(whiptail --title "Database" --inputbox "DB user:" 10 70 "$DEF_DB_USER" 3>&1 1>&2 2>&3) || exit 1

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

# ---------------- Install Docker + docker-compose (classic) ----------------
msg "Installing Docker + docker-compose inside the container..."
pct exec "${CTID}" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "apt-get -y install ca-certificates curl openssl docker.io docker-compose"
pct exec "${CTID}" -- bash -lc "systemctl enable --now docker"

# ---------------- Generate secrets ----------------
AUTH_KEY="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 32')"  # recommended [2](https://docs.romm.app/4.5.0/Getting-Started/Quick-Start-Guide/)
if [[ -z "${DB_ROOT_PASS}" ]]; then
  DB_ROOT_PASS="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 16')"
fi
if [[ -z "${DB_PASS}" ]]; then
  DB_PASS="$(pct exec "${CTID}" -- bash -lc 'openssl rand -hex 16')"
fi

# ---------------- Prepare local files (host) and pct push ----------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ENV_FILE="${TMPDIR}/.env"
COMPOSE_FILE="${TMPDIR}/docker-compose.yml"

cat > "${ENV_FILE}" <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWD=${DB_PASS}
DB_ROOT_PASSWORD=${DB_ROOT_PASS}
ROMM_AUTH_SECRET_KEY=${AUTH_KEY}
ROMM_PORT=${ROMM_PORT}

# Optional metadata providers (fill later if you want)
IGDB_CLIENT_ID=
IGDB_CLIENT_SECRET=
SCREENSCRAPER_USER=
SCREENSCRAPER_PASSWORD=
RETROACHIEVEMENTS_API_KEY=
MOBYGAMES_API_KEY=
STEAMGRIDDB_API_KEY=
HASHEOUS_API_ENABLED=true
EOF

# Compose v1.29 compatible:
# - no start_interval
# - depends_on is simple list; we will start DB first and wait for health before starting RomM
cat > "${COMPOSE_FILE}" <<'EOF'
version: "3"

services:
  romm:
    image: rommapp/romm:latest
    container_name: romm
    restart: unless-stopped
    env_file: .env
    environment:
      - DB_HOST=romm-db
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWD=${DB_PASSWD}
      - ROMM_AUTH_SECRET_KEY=${ROMM_AUTH_SECRET_KEY}

      - IGDB_CLIENT_ID=${IGDB_CLIENT_ID}
      - IGDB_CLIENT_SECRET=${IGDB_CLIENT_SECRET}
      - SCREENSCRAPER_USER=${SCREENSCRAPER_USER}
      - SCREENSCRAPER_PASSWORD=${SCREENSCRAPER_PASSWORD}
      - RETROACHIEVEMENTS_API_KEY=${RETROACHIEVEMENTS_API_KEY}
      - MOBYGAMES_API_KEY=${MOBYGAMES_API_KEY}
      - STEAMGRIDDB_API_KEY=${STEAMGRIDDB_API_KEY}
      - HASHEOUS_API_ENABLED=${HASHEOUS_API_ENABLED}

    volumes:
      - ./resources:/romm/resources
      - ./redis-data:/redis-data
      - ./library:/romm/library
      - ./assets:/romm/assets
      - ./config:/romm/config
    ports:
      - "${ROMM_PORT}:8080"
    depends_on:
      - romm-db

  romm-db:
    image: mariadb:latest
    container_name: romm-db
    restart: unless-stopped
    env_file: .env
    environment:
      - MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
      - MARIADB_DATABASE=${DB_NAME}
      - MARIADB_USER=${DB_USER}
      - MARIADB_PASSWORD=${DB_PASSWD}
    volumes:
      - ./mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 5
EOF

# ---------------- Write stack inside CT ----------------
msg "Writing RomM docker-compose stack to /opt/romm ..."
pct exec "${CTID}" -- bash -lc "mkdir -p /opt/romm/{library,assets,config,resources,redis-data,mysql_data}"
pct push "${CTID}" "${ENV_FILE}" /opt/romm/.env --perms 0600
pct push "${CTID}" "${COMPOSE_FILE}" /opt/romm/docker-compose.yml --perms 0644
pct exec "${CTID}" -- bash -lc "touch /opt/romm/config/config.yml"

# ---------------- Start stack (DB first, wait healthy, then RomM) ----------------
msg "Starting RomM database first..."
pct exec "${CTID}" -- bash -lc "cd /opt/romm && docker-compose up -d romm-db"

msg "Waiting for romm-db to become healthy..."
pct exec "${CTID}" -- bash -lc '
set -e
for i in $(seq 1 90); do
  status=$(docker inspect -f "{{.State.Health.Status}}" romm-db 2>/dev/null || echo "starting")
  if [ "$status" = "healthy" ]; then
    echo "[+] romm-db is healthy"
    exit 0
  fi
  echo "[*] romm-db status: $status (try $i/90)"
  sleep 2
done
echo "[!] romm-db did not become healthy in time"
docker logs --tail=80 romm-db || true
exit 1
'

msg "Starting RomM application..."
pct exec "${CTID}" -- bash -lc "cd /opt/romm && docker-compose up -d romm"

CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"

msg "Done ✅"
echo "RomM URL: http://${CTIP:-<CT_IP>}:${ROMM_PORT}"
echo "CTID/VMID: ${CTID}"
echo "Stack path inside CT: /opt/romm"
echo "Secrets stored in: /opt/romm/.env"
echo "Security tip: restrict ${ROMM_PORT}/tcp via Proxmox firewall to LAN/VPN only."
if [[ "${PRIVMODE}" == "unprivileged" ]]; then
  echo
  echo "NOTE: You chose an unprivileged LXC. If Docker has issues, re-create as privileged (recommended) or adjust LXC security settings."
fi
