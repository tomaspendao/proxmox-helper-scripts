#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Proxmox VE - Create Debian 12 LXC + Install Docker + GitLab Runner (menu-driven)
# Fixes:
#  - Auto-detect template storage that supports "vztmpl"
#  - Auto-detect next free VMID/CTID (pvesh /cluster/nextid + fallback)
#  - Auto-detect latest Debian 12 template name from: pveam available --section system
# Default network: DHCP (Static optional), VLAN-tagged bridge
# -------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"

msg()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# --- Requirements on Proxmox host ---
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

# --- Helpers: next free VMID/CTID ---
get_next_id() {
  if command -v pvesh >/dev/null 2>&1; then
    local nid
    nid="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "${nid}" && "${nid}" =~ ^[0-9]+$ ]]; then
      echo "${nid}"
      return 0
    fi
  fi

  local max_id=99
  if command -v pct >/dev/null 2>&1; then
    local pct_max
    pct_max="$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
    [[ -n "${pct_max:-}" && "${pct_max}" =~ ^[0-9]+$ ]] && (( pct_max > max_id )) && max_id=$pct_max
  fi
  if command -v qm >/dev/null 2>&1; then
    local qm_max
    qm_max="$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
    [[ -n "${qm_max:-}" && "${qm_max}" =~ ^[0-9]+$ ]] && (( qm_max > max_id )) && max_id=$qm_max
  fi
  echo $((max_id + 1))
}

is_vmid_free() {
  local id="$1"
  if command -v pct >/dev/null 2>&1; then
    if pct status "$id" >/dev/null 2>&1; then return 1; fi
  fi
  if command -v qm >/dev/null 2>&1; then
    if qm status "$id" >/dev/null 2>&1; then return 1; fi
  fi
  return 0
}

# --- Helper: get latest Debian 12 template name ---
get_latest_debian12_template() {
  pveam update >/dev/null

  local t
  t="$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$' \
      | sort -V \
      | tail -n 1 || true)"

  if [[ -z "${t}" ]]; then
    return 1
  fi
  echo "${t}"
  return 0
}

# ---------------- Defaults (PUBLIC) ----------------
DEF_HOSTNAME="gitlab-runner"
DEF_BRIDGE="vmbr0"
DEF_VLAN_TAG="20"

DEF_CORES="2"
DEF_MEM="2048"
DEF_SWAP="512"
DEF_DISK="16"
DEF_STORAGE="local-lvm"          # rootfs storage (user can change in menu)

# Static IP defaults (only used if Static selected)
DEF_IP="10.10.20.50/24"
DEF_GW="10.10.20.1"

# GitLab Runner defaults
DEF_GITLAB_URL="https://gitlab.com"
DEF_RUNNER_DESC="tmm-cluster-optiplex3040-runner"
DEF_RUNNER_TAGS="proxmox,homelab"

msg "Running script version: ${SCRIPT_VERSION}"

# ---------------- Auto-detect template storage (vztmpl) ----------------
DEF_TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
if [[ -z "${DEF_TEMPLATE_STORE}" ]]; then
  die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local) in Datacenter -> Storage."
fi

# ---------------- Auto-detect latest Debian 12 template ----------------
msg "Detecting latest Debian 12 LXC template via pveam available..."
DEF_TEMPLATE="$(get_latest_debian12_template || true)"
if [[ -z "${DEF_TEMPLATE:-}" ]]; then
  die "Could not find a Debian 12 template in 'pveam available --section system'. Check internet/DNS and run: pveam update; pveam available --section system | grep debian-12"
fi
msg "Selected template: ${DEF_TEMPLATE}"

# ---------------- Menus ----------------

CTID_MODE=$(whiptail --title "gitlab-runner LXC" --menu "CTID selection:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recommended)" \
  "manual" "Manually enter CTID" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "gitlab-runner LXC" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi

if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then
  die "Invalid CTID: ${CTID}"
fi
if ! is_vmid_free "${CTID}"; then
  die "CTID/VMID ${CTID} already exists. Choose another or use AUTO."
fi
msg "Using CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "gitlab-runner LXC" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
BRIDGE=$(whiptail --title "Network" --inputbox "Bridge (e.g. vmbr0):" 10 70 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 1
VLAN_TAG=$(whiptail --title "Network" --inputbox "VLAN tag (Management VLAN):" 10 70 "$DEF_VLAN_TAG" 3>&1 1>&2 2>&3) || exit 1

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
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR (e.g. 10.10.20.50/24):" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway (e.g. 10.10.20.1):" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

GITLAB_URL=$(whiptail --title "GitLab Runner" --inputbox "GitLab instance URL:" 10 70 "$DEF_GITLAB_URL" 3>&1 1>&2 2>&3) || exit 1
RUNNER_TOKEN=$(whiptail --title "GitLab Runner" --passwordbox "Runner authentication token (glrt-...) from GitLab > Settings > CI/CD > Runners > New project runner:" 12 78 3>&1 1>&2 2>&3) || exit 1
RUNNER_DESC=$(whiptail --title "GitLab Runner" --inputbox "Runner description:" 10 70 "$DEF_RUNNER_DESC" 3>&1 1>&2 2>&3) || exit 1
RUNNER_TAGS=$(whiptail --title "GitLab Runner" --inputbox "Runner tags (comma-separated):" 10 70 "$DEF_RUNNER_TAGS" 3>&1 1>&2 2>&3) || exit 1

if [[ -z "${RUNNER_TOKEN}" ]]; then
  die "Runner token cannot be empty. Get it from GitLab: Settings > CI/CD > Runners > New project runner."
fi

# ---------------- Template download ----------------
msg "Checking Debian LXC template in '${DEF_TEMPLATE_STORE}'..."
if ! pveam list "${DEF_TEMPLATE_STORE}" | awk '{print $1}' | grep -q "${DEF_TEMPLATE}"; then
  msg "Template not found locally. Downloading: ${DEF_TEMPLATE}"
  pveam download "${DEF_TEMPLATE_STORE}" "${DEF_TEMPLATE}"
else
  msg "Template already present: ${DEF_TEMPLATE}"
fi

# ---------------- Create CT ----------------
msg "Creating LXC ${CTID} (${HOSTNAME})..."
NETCFG="name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},ip=${IPCFG}"
if [[ "$IPCFG" != "dhcp" && -n "$GW" ]]; then
  NETCFG="${NETCFG},gw=${GW}"
fi

pct create "${CTID}" "${DEF_TEMPLATE_STORE}:vztmpl/${DEF_TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEM}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "${NETCFG}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --start 1

# ---------------- Bootstrap: base packages ----------------
msg "Updating container and installing prerequisites..."
pct exec "${CTID}" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "apt-get -y install curl ca-certificates sudo git gnupg lsb-release"

# ---------------- Install Docker (official convenience script) ----------------
msg "Installing Docker inside the LXC..."
pct exec "${CTID}" -- bash -lc "curl -fsSL https://get.docker.com | sh"
pct exec "${CTID}" -- bash -lc "systemctl enable --now docker"

# ---------------- Install GitLab Runner ----------------
msg "Installing GitLab Runner..."
pct exec "${CTID}" -- bash -lc "curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash"
pct exec "${CTID}" -- bash -lc "apt-get -y install gitlab-runner"

# ---------------- Register the runner (Docker executor) ----------------
msg "Registering GitLab Runner (Docker executor) against project ${GITLAB_URL}..."
pct exec "${CTID}" -- bash -lc "gitlab-runner register \
  --non-interactive \
  --url '${GITLAB_URL}' \
  --token '${RUNNER_TOKEN}' \
  --executor 'docker' \
  --docker-image 'alpine:latest' \
  --description '${RUNNER_DESC}' \
  --tag-list '${RUNNER_TAGS}' \
  --docker-privileged=false"

msg "Enabling and starting service: gitlab-runner"
pct exec "${CTID}" -- bash -lc "systemctl enable --now gitlab-runner"

CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
msg "Done ✅"
echo "CTID/VMID: ${CTID}"
echo "Hostname: ${HOSTNAME}"
echo "IP: ${CTIP:-<CT_IP>}"
echo "VLAN: ${VLAN_TAG} (bridge ${BRIDGE})"
echo "GitLab Runner registered against: ${GITLAB_URL} (tags: ${RUNNER_TAGS})"
echo "Executor: docker (privileged=false)"
echo "Tip: verify registration with: pct exec ${CTID} -- gitlab-runner verify"
