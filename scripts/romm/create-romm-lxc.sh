#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.1"

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

# RomM defaults
DEF_ROMM_PORT="8081"    # external port (container binds 8080 internally)
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

