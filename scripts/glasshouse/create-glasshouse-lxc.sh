#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Proxmox VE - Create Debian 12 LXC as a Glasshouse (lg-webos-dashboard)
# deploy/management host (menu-driven)
#
# Glasshouse runs ON the rooted LG webOS TV itself. This LXC is the
# persistent "computer on the same network" that the upstream project
# expects: it holds the repo clone, the SSH key for the TV, and a
# `glasshouse` wrapper to install/update/check the server on the TV.
#
# Upstream: https://github.com/rorygallagher2024/lg-webos-dashboard
# -------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"

msg()  { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\n\033[1;31m[✗]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need pct; need pveam; need pvesm; need awk; need grep; need sort; need tail; need tr

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
    if [[ -n "${nid}" && "${nid}" =~ ^[0-9]+$ ]]; then echo "${nid}"; return 0; fi
  fi
  local max_id=99 x
  x="$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
  [[ -n "${x:-}" && "${x}" =~ ^[0-9]+$ ]] && (( x > max_id )) && max_id=$x
  if command -v qm >/dev/null 2>&1; then
    x="$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
    [[ -n "${x:-}" && "${x}" =~ ^[0-9]+$ ]] && (( x > max_id )) && max_id=$x
  fi
  echo $((max_id + 1))
}

is_vmid_free() {
  local id="$1"
  pct status "$id" >/dev/null 2>&1 && return 1
  if command -v qm >/dev/null 2>&1; then qm status "$id" >/dev/null 2>&1 && return 1; fi
  return 0
}

get_latest_debian12_template() {
  pveam update >/dev/null
  local t
  t="$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$' \
      | sort -V | tail -n 1 || true)"
  [[ -z "${t}" ]] && return 1
  echo "${t}"
}

# ---------------- Defaults (PUBLIC) ----------------
DEF_HOSTNAME="glasshouse"
DEF_BRIDGE="vmbr0"
DEF_VLAN_TAG="20"

DEF_CORES="1"
DEF_MEM="512"
DEF_SWAP="256"
DEF_DISK="4"
DEF_STORAGE="local-lvm"

DEF_IP="10.10.20.60/24"
DEF_GW="10.10.20.1"

DEF_REPO_URL="https://github.com/rorygallagher2024/lg-webos-dashboard.git"
DEF_REPO_REF="main"
DEF_TV_IP=""

TITLE="glasshouse LXC"

msg "Running script version: ${SCRIPT_VERSION}"

DEF_TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
[[ -z "${DEF_TEMPLATE_STORE}" ]] && die "No storage with content 'vztmpl' found. Enable 'Container template' on a storage (e.g. local) in Datacenter -> Storage."

msg "Detecting latest Debian 12 LXC template via pveam available..."
DEF_TEMPLATE="$(get_latest_debian12_template || true)"
[[ -z "${DEF_TEMPLATE:-}" ]] && die "Could not find a Debian 12 template. Check internet/DNS and run: pveam update"
msg "Selected template: ${DEF_TEMPLATE}"

# ---------------- Menus ----------------
CTID_MODE=$(whiptail --title "$TITLE" --menu "CTID selection:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recommended)" \
  "manual" "Manually enter CTID" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "$TITLE" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi
[[ "${CTID}" =~ ^[0-9]+$ ]] || die "Invalid CTID: ${CTID}"
is_vmid_free "${CTID}" || die "CTID/VMID ${CTID} already exists. Choose another or use AUTO."
msg "Using CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
BRIDGE=$(whiptail --title "Network" --inputbox "Bridge (e.g. vmbr0):" 10 70 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 1
VLAN_TAG=$(whiptail --title "Network" --inputbox "VLAN tag (empty = untagged):" 10 70 "$DEF_VLAN_TAG" 3>&1 1>&2 2>&3) || exit 1

CORES=$(whiptail --title "Resources" --inputbox "CPU cores:" 10 70 "$DEF_CORES" 3>&1 1>&2 2>&3) || exit 1
MEM=$(whiptail --title "Resources" --inputbox "RAM (MB):" 10 70 "$DEF_MEM" 3>&1 1>&2 2>&3) || exit 1
SWAP=$(whiptail --title "Resources" --inputbox "SWAP (MB):" 10 70 "$DEF_SWAP" 3>&1 1>&2 2>&3) || exit 1
DISK=$(whiptail --title "Resources" --inputbox "Disk (GB):" 10 70 "$DEF_DISK" 3>&1 1>&2 2>&3) || exit 1
STORAGE=$(whiptail --title "Storage" --inputbox "Storage ID for rootfs (e.g. local-lvm/local):" 10 70 "$DEF_STORAGE" 3>&1 1>&2 2>&3) || exit 1

NETMODE=$(whiptail --title "Network" --menu "IP configuration:" 12 70 2 \
  "dhcp"   "Use DHCP (default)" \
  "static" "Use Static IP (required on VLANs without DHCP)" \
  3>&1 1>&2 2>&3) || exit 1

IPCFG="dhcp"; GW=""
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "Static IP/CIDR:" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway:" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

REPO_URL=$(whiptail --title "Glasshouse" --inputbox "Upstream repository URL:" 10 78 "$DEF_REPO_URL" 3>&1 1>&2 2>&3) || exit 1
REPO_REF=$(whiptail --title "Glasshouse" --inputbox "Branch or tag to track (e.g. main, v1.2.0):" 10 70 "$DEF_REPO_REF" 3>&1 1>&2 2>&3) || exit 1
TV_IP=$(whiptail --title "Glasshouse" --inputbox "LG TV IP address (optional, can be set later in /etc/glasshouse.conf):" 10 78 "$DEF_TV_IP" 3>&1 1>&2 2>&3) || exit 1

if [[ -n "${TV_IP}" && ! "${TV_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  die "Invalid TV IP: ${TV_IP}"
fi

# ---------------- Template download ----------------
if ! pveam list "${DEF_TEMPLATE_STORE}" | awk '{print $1}' | grep -q "${DEF_TEMPLATE}"; then
  msg "Downloading template: ${DEF_TEMPLATE}"
  pveam download "${DEF_TEMPLATE_STORE}" "${DEF_TEMPLATE}"
else
  msg "Template already present: ${DEF_TEMPLATE}"
fi

# ---------------- Create CT ----------------
msg "Creating LXC ${CTID} (${HOSTNAME})..."
NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
[[ -n "${VLAN_TAG}" ]] && NETCFG="${NETCFG},tag=${VLAN_TAG}"
[[ "$IPCFG" != "dhcp" && -n "$GW" ]] && NETCFG="${NETCFG},gw=${GW}"

pct create "${CTID}" "${DEF_TEMPLATE_STORE}:vztmpl/${DEF_TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEM}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "${NETCFG}" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1

msg "Waiting for network inside the container..."
for _ in $(seq 1 30); do
  pct exec "${CTID}" -- bash -c "getent hosts github.com >/dev/null 2>&1" && break
  sleep 2
done

# ---------------- Bootstrap ----------------
msg "Updating container and installing prerequisites..."
pct exec "${CTID}" -- bash -lc "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "DEBIAN_FRONTEND=noninteractive apt-get -y install git openssh-client curl ca-certificates"

msg "Cloning Glasshouse (${REPO_REF})..."
pct exec "${CTID}" -- bash -lc "git clone --branch '${REPO_REF}' '${REPO_URL}' /opt/glasshouse"

msg "Generating SSH key for the TV (ed25519, no passphrase, stays in the LXC)..."
pct exec "${CTID}" -- bash -lc "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
  [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C 'glasshouse@${HOSTNAME}' -f /root/.ssh/id_ed25519"

msg "Writing /etc/glasshouse.conf..."
pct exec "${CTID}" -- bash -lc "cat > /etc/glasshouse.conf <<CONF
# Glasshouse deploy host configuration
TV_IP=\"${TV_IP}\"
REPO_DIR=\"/opt/glasshouse\"
REPO_REF=\"${REPO_REF}\"
CONF
chmod 644 /etc/glasshouse.conf"

msg "Installing /usr/local/bin/glasshouse wrapper..."
pct exec "${CTID}" -- bash -lc "cat > /usr/local/bin/glasshouse <<'WRAP'
#!/usr/bin/env bash
# glasshouse - manage the Glasshouse server on a rooted LG webOS TV from this LXC
set -euo pipefail
# shellcheck disable=SC1091
. /etc/glasshouse.conf
TV=\"\${TV_IP:-}\"

usage() {
  cat <<U
Usage: glasshouse <command> [args]
  key               print this host's SSH public key (add it to the TV)
  ssh               open a root shell on the TV over SSH
  pull              update the local repo clone (\${REPO_REF})
  deploy [opts]     pull + install/update the server on the TV
                    (opts passed to deploy.sh: --telnet --no-persist --app --no-app)
  status            check the dashboard HTTP endpoint on the TV
  version           show the checked-out upstream commit
TV_IP is read from /etc/glasshouse.conf (current: \${TV:-<unset>})
U
}

need_tv() { [ -n \"\$TV\" ] || { echo \"TV_IP not set in /etc/glasshouse.conf\" >&2; exit 2; }; }
pull() {
  git -C \"\$REPO_DIR\" fetch --tags --quiet origin
  git -C \"\$REPO_DIR\" checkout --quiet \"\$REPO_REF\"
  git -C \"\$REPO_DIR\" pull --ff-only --quiet origin \"\$REPO_REF\" 2>/dev/null || true
  git -C \"\$REPO_DIR\" log -1 --format='%h %cs %s'
}

case \"\${1:-}\" in
  key)     cat /root/.ssh/id_ed25519.pub ;;
  ssh)     need_tv; exec ssh -o StrictHostKeyChecking=accept-new \"root@\$TV\" ;;
  pull)    pull ;;
  deploy)  need_tv; shift; pull; cd \"\$REPO_DIR/server\" && exec ./deploy.sh \"\$TV\" \"\$@\" ;;
  status)  need_tv; code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \"http://\$TV:8080/api/caps\" || true)
           case \"\$code\" in 200|401) echo \"up (HTTP \$code) - http://\$TV:8080/\";; *) echo \"down (HTTP \${code:-none})\"; exit 1;; esac ;;
  version) git -C \"\$REPO_DIR\" log -1 --format='%h %cs %s' ;;
  *)       usage; [ -n \"\${1:-}\" ] && exit 2 || exit 0 ;;
esac
WRAP
chmod 755 /usr/local/bin/glasshouse"

PUBKEY="$(pct exec "${CTID}" -- cat /root/.ssh/id_ed25519.pub)"
CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
UPSTREAM="$(pct exec "${CTID}" -- glasshouse version || true)"

msg "Done ✅"
echo "CTID/VMID: ${CTID}"
echo "Hostname:  ${HOSTNAME}"
echo "IP:        ${CTIP:-<CT_IP>}"
echo "VLAN:      ${VLAN_TAG:-untagged} (bridge ${BRIDGE})"
echo "Upstream:  ${UPSTREAM}"
echo "TV IP:     ${TV_IP:-<not set - edit /etc/glasshouse.conf>}"
echo
echo "SSH public key (add to the TV's /home/root/.ssh/authorized_keys):"
echo "  ${PUBKEY}"
echo
echo "Next steps (TV must already be rooted with Homebrew Channel):"
echo "  pct enter ${CTID}"
echo "  glasshouse deploy           # first install (telnet fallback if SSH not set up)"
echo "  glasshouse status"
