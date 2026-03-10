#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Proxmox VE - Create Debian 12 LXC + Install & Run Geekbench 6 (menu-driven)
# Features:
#  - Auto-detect template storage that supports "vztmpl"
#  - Auto-detect next free VMID/CTID (pvesh /cluster/nextid + fallback)
#  - Auto-detect latest Debian 12 template name from: pveam available --section system
# Default network: DHCP (Static optional)
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
  warn "whiptail não está instalado no host Proxmox."
  echo "Instala: apt update && apt install -y whiptail"
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

  [[ -n "${t}" ]] || return 1
  echo "${t}"
}

# ---------------- Defaults (PUBLIC) ----------------
DEF_HOSTNAME="geekbench6"
DEF_BRIDGE="vmbr0"

DEF_CORES="2"
DEF_MEM="2048"
DEF_SWAP="512"
DEF_DISK="8"
DEF_STORAGE="local-lvm"          # rootfs storage (user can change in menu)

# Static IP defaults (only used if Static selected)
DEF_IP="192.168.1.50/24"
DEF_GW="192.168.1.1"

# Geekbench defaults
# Using a known current Linux tarball naming format: Geekbench-6.6.0-Linux.tar.gz
DEF_GB_VERSION="6.6.0"
DEF_RUN_NOW="yes"      # run benchmark after install
DEF_STOP_AFTER="no"    # stop container after run

msg "Running script version: ${SCRIPT_VERSION}"

# ---------------- Auto-detect template storage (vztmpl) ----------------
DEF_TEMPLATE_STORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')"
if [[ -z "${DEF_TEMPLATE_STORE}" ]]; then
  die "Nenhum storage com conteúdo 'vztmpl' encontrado. Ativa 'Container template' num storage (ex: local) em Datacenter -> Storage."
fi

# ---------------- Auto-detect latest Debian 12 template ----------------
msg "A detectar o template Debian 12 mais recente via pveam available..."
DEF_TEMPLATE="$(get_latest_debian12_template || true)"
if [[ -z "${DEF_TEMPLATE:-}" ]]; then
  die "Não consegui encontrar template Debian 12 em 'pveam available --section system'. Verifica internet/DNS e corre: pveam update"
fi
msg "Template selecionado: ${DEF_TEMPLATE}"

# ---------------- Menus ----------------
CTID_MODE=$(whiptail --title "Geekbench 6 LXC" --menu "Seleção do CTID:" 12 70 2 \
  "auto"   "Auto-detect next free ID (recomendado)" \
  "manual" "Inserir CTID manualmente" \
  3>&1 1>&2 2>&3) || exit 1

if [[ "$CTID_MODE" == "auto" ]]; then
  CTID="$(get_next_id)"
else
  CTID=$(whiptail --title "Geekbench 6 LXC" --inputbox "CTID (Container ID):" 10 70 "$(get_next_id)" 3>&1 1>&2 2>&3) || exit 1
fi

if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then
  die "CTID inválido: ${CTID}"
fi
if ! is_vmid_free "${CTID}"; then
  die "CTID/VMID ${CTID} já existe. Escolhe outro ou usa AUTO."
fi
msg "A usar CTID/VMID: ${CTID}"

HOSTNAME=$(whiptail --title "Geekbench 6 LXC" --inputbox "Hostname:" 10 70 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1
BRIDGE=$(whiptail --title "Network" --inputbox "Bridge (ex: vmbr0):" 10 70 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 1

CORES=$(whiptail --title "Resources" --inputbox "CPU cores:" 10 70 "$DEF_CORES" 3>&1 1>&2 2>&3) || exit 1
MEM=$(whiptail --title "Resources" --inputbox "RAM (MB):" 10 70 "$DEF_MEM" 3>&1 1>&2 2>&3) || exit 1
SWAP=$(whiptail --title "Resources" --inputbox "SWAP (MB):" 10 70 "$DEF_SWAP" 3>&1 1>&2 2>&3) || exit 1
DISK=$(whiptail --title "Resources" --inputbox "Disk (GB):" 10 70 "$DEF_DISK" 3>&1 1>&2 2>&3) || exit 1

STORAGE=$(whiptail --title "Storage" --inputbox "Storage ID para rootfs (ex: local-lvm/local):" 10 70 "$DEF_STORAGE" 3>&1 1>&2 2>&3) || exit 1

NETMODE=$(whiptail --title "Network" --menu "Configuração de IP:" 12 70 2 \
  "dhcp"   "Usar DHCP (default)" \
  "static" "Usar IP estático" \
  3>&1 1>&2 2>&3) || exit 1

IPCFG="dhcp"
GW=""
if [[ "$NETMODE" == "static" ]]; then
  IPCFG=$(whiptail --title "Network" --inputbox "IP/CIDR (ex: 192.168.1.50/24):" 10 70 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 1
  GW=$(whiptail --title "Network" --inputbox "Gateway (ex: 192.168.1.1):" 10 70 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 1
fi

GB_VERSION=$(whiptail --title "Geekbench 6" --inputbox "Versão do Geekbench 6 (ex: 6.6.0):" 10 70 "$DEF_GB_VERSION" 3>&1 1>&2 2>&3) || exit 1

RUN_NOW=$(whiptail --title "Geekbench 6" --menu "Executar benchmark no fim?" 12 70 2 \
  "yes" "Sim, executar já" \
  "no"  "Não, só instalar" \
  3>&1 1>&2 2>&3) || exit 1

STOP_AFTER=$(whiptail --title "Geekbench 6" --menu "Parar o LXC no fim?" 12 70 2 \
  "no"  "Não (recomendado se quiseres repetir)" \
  "yes" "Sim (bom para bench único)" \
  3>&1 1>&2 2>&3) || exit 1

# ---------------- Template download ----------------
msg "A verificar template Debian em '${DEF_TEMPLATE_STORE}'..."
if ! pveam list "${DEF_TEMPLATE_STORE}" | awk '{print $1}' | grep -q "${DEF_TEMPLATE}"; then
  msg "Template não encontrado localmente. A descarregar: ${DEF_TEMPLATE}"
  pveam download "${DEF_TEMPLATE_STORE}" "${DEF_TEMPLATE}"
else
  msg "Template já presente: ${DEF_TEMPLATE}"
fi

# ---------------- Create CT ----------------
msg "A criar LXC ${CTID} (${HOSTNAME})..."
NETCFG="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
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

# ---------------- Bootstrap ----------------
msg "A atualizar container e instalar pré-requisitos..."
pct exec "${CTID}" -- bash -lc "apt-get update && apt-get -y upgrade"
pct exec "${CTID}" -- bash -lc "apt-get -y install wget tar ca-certificates"

msg "A instalar Geekbench 6 (Linux tarball)..."
pct exec "${CTID}" -- bash -lc "mkdir -p /opt/geekbench && cd /opt/geekbench && \
wget -q https://cdn.geekbench.com/Geekbench-${GB_VERSION}-Linux.tar.gz -O geekbench.tar.gz && \
tar -xzf geekbench.tar.gz && \
ln -sf /opt/geekbench/Geekbench-${GB_VERSION}-Linux/geekbench6 /usr/local/bin/geekbench6 && \
ln -sf /opt/geekbench/Geekbench-${GB_VERSION}-Linux/geekbench6-compute /usr/local/bin/geekbench6-compute || true"

if [[ "${RUN_NOW}" == "yes" ]]; then
  msg "A correr Geekbench 6 (CPU)..."
  pct exec "${CTID}" -- bash -lc "geekbench6 | tee /root/geekbench-result.txt"

  CTIP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
  msg "Benchmark concluído ✅"
  echo "CTID/VMID: ${CTID}"
  echo "CT IP: ${CTIP:-<CT_IP>}"
  echo "Resultados (no LXC): /root/geekbench-result.txt"
  echo "Ver no host: pct exec ${CTID} -- cat /root/geekbench-result.txt"
else
  msg "Instalação concluída ✅ (benchmark não executado)."
  echo "CTID/VMID: ${CTID}"
  echo "Executa depois: pct exec ${CTID} -- geekbench6 | tee /root/geekbench-result.txt"
fi

if [[ "${STOP_AFTER}" == "yes" ]]; then
  msg "A parar LXC ${CTID}..."
  pct stop "${CTID}" >/dev/null
  msg "LXC parado."
fi

msg "Done ✅"
