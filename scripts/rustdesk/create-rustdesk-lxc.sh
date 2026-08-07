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

# -------------------------------------------------------------------
# Proxmox VE - Create Debian 12 LXC + Install RustDesk Server OSS (Docker)
#
# WHY LXC AND NOT A VM:
#   RustDesk Server OSS (hbbs + hbbr) is a couple of lightweight Rust
#   binaries running in Docker. It needs no custom kernel, no nested
#   virtualization, no GPU passthrough - an LXC gives instant boot,
#   near-zero overhead and fits the same pattern as the other scripts
#   in this repo (code-server, romm, geekbench6). A VM would only make
#   sense here if you needed kernel-level isolation from the host,
#   which isn't a requirement for this workload.
#
# Deploys hbbs (ID/rendezvous server) + hbbr (relay server) via docker-compose
# Optionally installs Tailscale inside the container for secure remote access.
# Reference: https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/
# -------------------------------------------------------------------

SCRIPT_VERSION="1.3.0"

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
DEF_HOSTNAME="rustdesk"
DEF_BRIDGE="vmbr0"
DEF_CORES="1"
DEF_MEM="1024"
DEF_SWAP="512"
DEF_DISK="8"
DEF_STORAGE="local-lvm"

# RustDesk Server OSS fixed protocol ports (do not change unless you know why)
HBBS_TCP_PORTS="21115,21116,21118"
HBBS_UDP_PORTS="21116"
HBBR_TCP_PORTS="21117,21119"

# ---------------- Detect template storage (vztmpl) ----------------
TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
[[ -z "${TEMPLATE_STORE}" ]] && die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local)."

# ---------------- Detect latest Debian 12 template ----------------
msg "Detecting latest Debian 12 LXC template..."
TEMPLATE_NAME="$(get_latest_debian12_template || true)"
[[ -z "${TEMPLATE_NAME:-}" ]] && die "No Debian 12 template found. Try: pveam update; pveam available --section system | grep debian-12"
msg "Selected template: ${TEMPLATE_NAME}"

# ---------------- Menus ----------------
CTID_MODE=$(whiptail --title "RustDesk Server LXC" --menu "CTID selection:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recommended)" \
  "manual" "Manually enter CTID" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "RustDesk Server LXC" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi

[[ ! "${CTID}" =~ ^[0-9]+$ ]] && die "Invalid CTID: ${CTID}"
is_vmid_free "${CTID}" || die "CTID/VMID ${CTID} already exists."
msg "Using CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "RustDesk Server LXC" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
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
DEF_IP="192.168.1.61/24"
DEF_GW="192.168.1.1"
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR:" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway:" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

PRIVMODE=$(whiptail --title "Container security" --menu "Container type (Docker compatibility):" 12 80 2 \
  "privileged"   "Privileged (recommended for Docker compatibility)" \
  "unprivileged" "Unprivileged (more secure, may need extra tweaks)" \
  3>&1 1>&2 2>&3) || exit 1

INSTALL_TS=$(whiptail --title "Tailscale" --menu "Install Tailscale inside this LXC?" 14 78 2 \
  "yes" "Recommended: secure remote access without exposing ports to the internet" \
  "no"  "Skip Tailscale, LAN/VPN access only through this LXC's own network" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$INSTALL_TS" == "yes" ]]; then
  RELAY_MODE=$(whiptail --title "RustDesk" --menu "Relay/ID server address (what clients will connect to):" 15 78 3 \
    "tailscale" "Use this LXC's Tailscale IP (recommended, no port forwarding needed)" \
    "auto"      "Use this LXC's LAN IP (LAN/VPN only)" \
    "custom"    "Enter a domain or fixed IP manually" \
    3>&1 1>&2 2>&3) || exit 1
else
  RELAY_MODE=$(whiptail --title "RustDesk" --menu "Relay/ID server address (what clients will connect to):" 14 78 2 \
    "auto"   "Use this LXC's LAN IP automatically (recommended for LAN/VPN)" \
    "custom" "Enter a domain or fixed IP manually (e.g. behind a reverse proxy)" \
    3>&1 1>&2 2>&3) || exit 1
fi

CUSTOM_RELAY=""
if [[ "$RELAY_MODE" == "custom" ]]; then
  CUSTOM_RELAY=$(whiptail --title "RustDesk" --inputbox "Domain or IP clients will use to reach hbbs:" 10 70 "" 3>&1 1>&2 2>&3) || exit 1
  [[ -z "${CUSTOM_RELAY}" ]] && die "Relay address cannot be empty in custom mode."
fi

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

# ---------------- Grant /dev/net/tun access (required for Tailscale) ----------------
# Without this, tailscaled installs fine but fails to start inside the LXC
# ("open /dev/net/tun: no such file or directory"). This must be set on the
# Proxmox host, in the container's config file, not from inside the LXC.
if [[ "${INSTALL_TS}" == "yes" ]]; then
  msg "Granting /dev/net/tun access to the LXC (required for Tailscale)..."
  CTCONF="/etc/pve/lxc/${CTID}.conf"
  if [[ -f "${CTCONF}" ]]; then
    grep -q "^lxc.cgroup2.devices.allow: c 10:200 rwm" "${CTCONF}" 2>/dev/null || \
      echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "${CTCONF}"
    grep -q "^lxc.mount.entry: /dev/net dev/net none bind" "${CTCONF}" 2>/dev/null || \
      echo "lxc.mount.entry: /dev/net dev/net none bind,create=dir 0.0" >> "${CTCONF}"

    msg "Restarting the LXC to apply /dev/net/tun access..."
    pct stop "${CTID}"
    pct start "${CTID}"
    # Give the container a few seconds to bring networking back up before pct exec calls
    sleep 5
  else
    warn "Could not find ${CTCONF} to grant /dev/net/tun access. Tailscale may fail to start."
    warn "Fix manually on the Proxmox host with:"
    echo "  echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> /etc/pve/lxc/${CTID}.conf"
    echo "  echo 'lxc.mount.entry: /dev/net dev/net none bind,create=dir 0.0' >> /etc/pve/lxc/${CTID}.conf"
    echo "  pct stop ${CTID} && pct start ${CTID}"
  fi
fi

# ---------------- Install Docker + docker-compose (classic) ----------------
msg "Installing Docker + docker-compose inside the container..."
pct exec "${CTID}" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "apt-get -y install ca-certificates curl docker.io docker-compose"
pct exec "${CTID}" -- bash -lc "systemctl enable --now docker"

# ---------------- Install Tailscale (optional) ----------------
if [[ "${INSTALL_TS}" == "yes" ]]; then
  msg "Installing Tailscale inside the container..."
  pct exec "${CTID}" -- bash -lc "curl -fsSL https://tailscale.com/install.sh | sh"
  pct exec "${CTID}" -- bash -lc "systemctl enable --now tailscaled"

  msg "Authenticate this node with Tailscale - open the URL printed below in your browser."
  warn "The script will wait here until you approve the device in your Tailscale admin console."
  pct exec "${CTID}" -- tailscale up

  msg "Tailscale connected."
fi

# ---------------- Resolve relay address ----------------
CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"

case "$RELAY_MODE" in
  tailscale)
    TSIP="$(pct exec "${CTID}" -- bash -lc "tailscale ip -4 2>/dev/null" || true)"
    [[ -z "${TSIP}" ]] && die "Could not read Tailscale IP. Check status with: pct exec ${CTID} -- tailscale status"
    RELAY_ADDR="${TSIP}"
    ;;
  auto)
    [[ -z "${CTIP}" ]] && die "Could not detect the LXC's IP to use as relay address. Re-run with 'custom' mode instead."
    RELAY_ADDR="${CTIP}"
    ;;
  custom)
    RELAY_ADDR="${CUSTOM_RELAY}"
    ;;
esac
msg "hbbs relay/ID address that will be used: ${RELAY_ADDR}"

# ---------------- Prepare local files (host) and pct push ----------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ENV_FILE="${TMPDIR}/.env"
COMPOSE_FILE="${TMPDIR}/docker-compose.yml"

cat > "${ENV_FILE}" <<EOF
RELAY_ADDR=${RELAY_ADDR}
EOF

# network_mode: host is used per RustDesk's own docs, since hbbs/hbbr rely on
# UDP hole punching and matching ports; simplest and most reliable inside an LXC.
cat > "${COMPOSE_FILE}" <<'EOF'
version: "3"

services:
  hbbs:
    container_name: hbbs
    image: rustdesk/rustdesk-server:latest
    command: hbbs -r ${RELAY_ADDR}:21117
    volumes:
      - ./data:/root
    network_mode: "host"
    depends_on:
      - hbbr
    restart: unless-stopped

  hbbr:
    container_name: hbbr
    image: rustdesk/rustdesk-server:latest
    command: hbbr
    volumes:
      - ./data:/root
    network_mode: "host"
    restart: unless-stopped
EOF

# ---------------- Write stack inside CT ----------------
msg "Writing RustDesk docker-compose stack to /opt/rustdesk ..."
pct exec "${CTID}" -- bash -lc "mkdir -p /opt/rustdesk/data"
pct push "${CTID}" "${ENV_FILE}" /opt/rustdesk/.env --perms 0600
pct push "${CTID}" "${COMPOSE_FILE}" /opt/rustdesk/docker-compose.yml --perms 0644

# ---------------- Start stack (hbbr first, then hbbs) ----------------
msg "Starting hbbr (relay server)..."
pct exec "${CTID}" -- bash -lc "cd /opt/rustdesk && docker-compose up -d hbbr"

msg "Starting hbbs (ID/rendezvous server)..."
pct exec "${CTID}" -- bash -lc "cd /opt/rustdesk && docker-compose up -d hbbs"

# ---------------- Wait for keypair and read public key ----------------
# NOTE: we read the key straight from the bind-mounted ./data dir on the LXC
# (/opt/rustdesk/data/id_ed25519.pub), NOT via 'docker exec hbbs cat ...' -
# the rustdesk-server image is minimal and doesn't ship a 'cat' binary,
# which makes 'docker exec' fail with "executable file not found in $PATH".
msg "Waiting for hbbs to generate its keypair..."
PUBKEY=""
for i in $(seq 1 30); do
  PUBKEY="$(pct exec "${CTID}" -- bash -lc "cat /opt/rustdesk/data/id_ed25519.pub 2>/dev/null" || true)"
  [[ -n "${PUBKEY}" ]] && break
  sleep 2
done

msg "Done ✅"
echo "RustDesk Server (hbbs+hbbr) CTID/VMID: ${CTID}"
echo "Container LAN IP: ${CTIP:-<CT_IP>}"
if [[ "${INSTALL_TS}" == "yes" ]]; then
  echo "Container Tailscale IP: ${TSIP:-<check: pct exec ${CTID} -- tailscale ip -4>}"
fi
echo "Relay/ID address configured for clients: ${RELAY_ADDR}"
echo "Stack path inside CT: /opt/rustdesk"
echo
if [[ -n "${PUBKEY}" ]]; then
  echo "Public key (use this in client's 'Key' field):"
  echo "  ${PUBKEY}"
else
  warn "Could not read the public key yet. Retrieve it later with:"
  echo "  pct exec ${CTID} -- cat /opt/rustdesk/data/id_ed25519.pub"
fi
echo
if [[ "${RELAY_MODE}" == "tailscale" ]]; then
  echo "Access is restricted to devices on your tailnet - nothing needs to be exposed to the internet."
else
  echo "Ports to allow (LAN/VPN recommended, avoid exposing directly to the internet):"
  echo "  hbbs: TCP ${HBBS_TCP_PORTS} + UDP ${HBBS_UDP_PORTS}"
  echo "  hbbr: TCP ${HBBR_TCP_PORTS}"
fi
echo
echo "Client config: Server ID = ${RELAY_ADDR}, Relay Server = ${RELAY_ADDR}, Key = (public key above)"
if [[ "${PRIVMODE}" == "unprivileged" ]]; then
  echo
  echo "NOTE: You chose an unprivileged LXC. If Docker has issues, re-create as privileged (recommended) or adjust LXC security settings."
fi
