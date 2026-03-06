#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# (PUBLIC) Proxmox VE - Create Debian 12 LXC + Install code-server
# Fix: Auto-detect storage that supports LXC templates (content: vztmpl)
# Default network: DHCP (Static optional via menu)
# -------------------------------------------------------------------

msg()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need pct
need pveam
need pvesm

if ! command -v whiptail >/dev/null 2>&1; then
  warn "whiptail is not installed on Proxmox host."
  echo "Install: apt update && apt install -y whiptail"
  exit 1
fi

# ---------------- Defaults (PUBLIC) ----------------
DEF_CTID="120"
DEF_HOSTNAME="code-server"
DEF_BRIDGE="vmbr0"

DEF_CORES="2"
DEF_MEM="2048"
DEF_SWAP="512"
DEF_DISK="12"
DEF_STORAGE="local-lvm"

# Template file name (pveam uses this exact name)
DEF_TEMPLATE="debian-12-standard_12.0-1_amd64.tar.zst"

# Generic static defaults (only used if Static selected)
DEF_IP="192.168.1.20/24"
DEF_GW="192.168.1.1"

# code-server defaults
DEF_USER="coder"
DEF_PORT="8080"

# ---------------- Auto-detect template storage (vztmpl) ----------------
# Pick the first storage that supports container templates (content: vztmpl).
# This avoids: "400 Parameter verification failed. template: no such template"
DEF_TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"

if [[ -z "${DEF_TEMPLATE_STORE}" ]]; then
  die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local) in Datacenter -> Storage."
fi

# ---------------- Menus ----------------
CTID=$(whiptail --title "code-server LXC" --inputbox "CTID (Container ID):" 10 70 "$DEF_CTID" 3>&1 1>&2 2>&3) || exit 1
HOSTNAME=$(whiptail --title "code-server LXC" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
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
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR (e.g. 192.168.1.20/24):" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway (e.g. 192.168.1.1):" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

CS_USER=$(whiptail --title "code-server" --inputbox "Linux user to run code-server:" 10 70 "$DEF_USER" 3>&1 1>&2 2>&3) || exit 1
CS_PORT=$(whiptail --title "code-server" --inputbox "Port for code-server:" 10 70 "$DEF_PORT" 3>&1 1>&2 2>&3) || exit 1
CS_PASS=$(whiptail --title "code-server" --passwordbox "Set code-server password:" 10 70 3>&1 1>&2 2>&3) || exit 1

BINDMODE=$(whiptail --title "code-server" --menu "Bind address:" 12 80 2 \
  "0.0.0.0"   "Accessible from LAN/VPN (recommended)" \
  "127.0.0.1" "Localhost only (reverse proxy / SSH tunnel)" \
  3>&1 1>&2 2>&3) || exit 1

# ---------------- Checks ----------------
if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID $CTID already exists. Choose another CTID."
fi

# ---------------- Template download ----------------
msg "Checking Debian LXC template in '${DEF_TEMPLATE_STORE}'..."
if ! pveam list "${DEF_TEMPLATE_STORE}" | awk '{print $2}' | grep -qx "${DEF_TEMPLATE}"; then
  msg "Template not found. Downloading: ${DEF_TEMPLATE}"
  pveam update
  pveam download "${DEF_TEMPLATE_STORE}" "${DEF_TEMPLATE}"
else
  msg "Template OK: ${DEF_TEMPLATE}"
fi

# ---------------- Create CT ----------------
msg "Creating LXC $CTID ($HOSTNAME)..."
NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
if [[ "$IPCFG" != "dhcp" && -n "$GW" ]]; then
  NETCFG="${NETCFG},gw=${GW}"
fi

pct create "$CTID" "${DEF_TEMPLATE_STORE}:vztmpl/${DEF_TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEM" \
  --swap "$SWAP" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "$NETCFG" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --start 1

# ---------------- Bootstrap ----------------
msg "Updating container and installing prerequisites..."
pct exec "$CTID" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "$CTID" -- bash -lc "apt-get -y install curl ca-certificates sudo git"

msg "Creating user '$CS_USER'..."
pct exec "$CTID" -- bash -lc "id -u $CS_USER >/dev/null 2>&1 || adduser --disabled-password --gecos '' $CS_USER"
pct exec "$CTID" -- bash -lc "usermod -aG sudo $CS_USER"

msg "Installing code-server (official installer)..."
pct exec "$CTID" -- bash -lc "curl -fsSL https://code-server.dev/install.sh | sh"

msg "Configuring code-server..."
pct exec "$CTID" -- bash -lc "su - $CS_USER -c 'mkdir -p ~/.config/code-server'"

pct exec "$CTID" -- bash -lc "cat > /home/$CS_USER/.config/code-server/config.yaml <<EOF
bind-addr: ${BINDMODE}:${CS_PORT}
auth: password
password: ${CS_PASS}
cert: false
EOF
chown -R $CS_USER:$CS_USER /home/$CS_USER/.config/code-server
"

msg "Enabling and starting service: code-server@$CS_USER"
pct exec "$CTID" -- bash -lc "systemctl enable --now code-server@$CS_USER"

CTIP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
msg "Done ✅"
echo "Access URL: http://${CTIP:-<CT_IP>}:${CS_PORT}"
echo "User: ${CS_USER}"
echo "Tip: Restrict ${CS_PORT}/tcp via Proxmox firewall to LAN/VPN only."
