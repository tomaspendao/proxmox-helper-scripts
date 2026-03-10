#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Proxmox Helper Script: Geekbench 6 Benchmark (LXC)
# -----------------------------------------------------------------------------
# Creates a Debian 12 LXC, installs Geekbench 6 CLI and runs a benchmark.
#
# Repo:  https://github.com/tomaspendao/proxmox-helper-scripts
# Author: Tomás Pendão
# License: MIT
# Version: 1.0.0
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# -----------------------------[ Styling / UI ]------------------------------ #
YW=$'\033[33m'
RD=$'\033[31m'
GN=$'\033[32m'
BL=$'\033[36m'
CL=$'\033[0m'
BOLD=$'\033[1m'

msg()  { echo -e "${BL}==>${CL} $*"; }
ok()   { echo -e "${GN}✔${CL} $*"; }
warn() { echo -e "${YW}⚠${CL} $*"; }
err()  { echo -e "${RD}✖${CL} $*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
  # place for future cleanup if needed
  true
}
trap cleanup EXIT

# -----------------------------[ Requirements ]------------------------------ #
[[ "$(id -u)" -eq 0 ]] || die "Executa como root."
command -v pveversion >/dev/null 2>&1 || die "Isto não parece ser um host Proxmox (pveversion não encontrado)."
command -v pct >/dev/null 2>&1 || die "pct não encontrado (LXC tools)."
command -v pveam >/dev/null 2>&1 || die "pveam não encontrado."

# -----------------------------[ Defaults ]---------------------------------- #
APP="Geekbench 6"
HOSTNAME="geekbench6"
OS_TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"
CTID="$(pvesh get /cluster/nextid)"
DISK_GB="8"
MEM_MB="2048"
SWAP_MB="512"
CORES="2"
BRIDGE="vmbr0"
UNPRIV="1"
NESTING="1"
START_ONBOOT="0"
UPLOAD="0"  # 0=no upload, 1=upload results
GEEK_VER="6.3.0"

# -----------------------------[ Helpers ]----------------------------------- #
pick_storage() {
  # Try to pick a reasonable default rootfs storage
  # Prefer local-lvm if exists, else local
  if pvesm status --content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local-lvm"; then
    echo "local-lvm"
  else
    echo "local"
  fi
}

storage_is_valid() {
  local st="$1"
  pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$st"
}

bridge_is_valid() {
  local br="$1"
  ip link show "$br" >/dev/null 2>&1
}

press_enter() {
  read -r -p "Carrega ENTER para continuar..." _
}

# -----------------------------[ Header ]------------------------------------ #
clear
echo -e "${BOLD}${APP} (LXC) - Proxmox Helper Script${CL}"
echo "------------------------------------------------------------"
echo "Vai criar um LXC Debian 12 e correr Geekbench 6 (CPU benchmark)."
echo

# -----------------------------[ Simple menu ]------------------------------- #
ROOTFS_STORAGE="$(pick_storage)"

echo -e "${BOLD}Configuração (podes aceitar defaults):${CL}"
read -r -p "CTID [${CTID}]: " IN; CTID="${IN:-$CTID}"
read -r -p "Hostname [${HOSTNAME}]: " IN; HOSTNAME="${IN:-$HOSTNAME}"

read -r -p "RootFS storage [${ROOTFS_STORAGE}]: " IN; ROOTFS_STORAGE="${IN:-$ROOTFS_STORAGE}"
storage_is_valid "$ROOTFS_STORAGE" || die "Storage inválido: $ROOTFS_STORAGE"

read -r -p "Bridge [${BRIDGE}]: " IN; BRIDGE="${IN:-$BRIDGE}"
bridge_is_valid "$BRIDGE" || die "Bridge inválida: $BRIDGE"

read -r -p "Disco (GB) [${DISK_GB}]: " IN; DISK_GB="${IN:-$DISK_GB}"
read -r -p "RAM (MB) [${MEM_MB}]: " IN; MEM_MB="${IN:-$MEM_MB}"
read -r -p "SWAP (MB) [${SWAP_MB}]: " IN; SWAP_MB="${IN:-$SWAP_MB}"
read -r -p "vCPU cores [${CORES}]: " IN; CORES="${IN:-$CORES}"

read -r -p "Upload de resultados para Geekbench? (0/1) [${UPLOAD}]: " IN; UPLOAD="${IN:-$UPLOAD}"

echo
msg "Resumo:"
echo "  CTID:        $CTID"
echo "  Hostname:    $HOSTNAME"
echo "  Template:    $OS_TEMPLATE (storage: $TEMPLATE_STORAGE)"
echo "  RootFS:      $ROOTFS_STORAGE:${DISK_GB}G"
echo "  RAM/SWAP:    ${MEM_MB}MB / ${SWAP_MB}MB"
echo "  vCPU:        $CORES"
echo "  Bridge/IP:   $BRIDGE / DHCP"
echo "  Unprivileged:$UNPRIV  Nesting:$NESTING"
echo "  Upload:      $UPLOAD"
echo

press_enter

# -----------------------------[ Download template ]-------------------------- #
msg "A verificar template Debian 12..."
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$OS_TEMPLATE"; then
  msg "A descarregar template: $OS_TEMPLATE"
  pveam update >/dev/null 2>&1 || true
  pveam download "$TEMPLATE_STORAGE" "$OS_TEMPLATE"
  ok "Template descarregado."
else
  ok "Template já existe."
fi

# -----------------------------[ Create CT ]---------------------------------- #
msg "A criar LXC ($CTID)..."
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$OS_TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEM_MB" \
  --swap "$SWAP_MB" \
  --rootfs "$ROOTFS_STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
  --features "nesting=$NESTING" \
  --unprivileged "$UNPRIV" \
  --onboot "$START_ONBOOT" \
  --ostype debian \
  --tags "benchmark;geekbench6" >/dev/null

ok "LXC criado."

msg "A iniciar LXC..."
pct start "$CTID" >/dev/null
ok "LXC iniciado."

msg "A aguardar boot (10s)..."
sleep 10

# -----------------------------[ Install deps + Geekbench ]------------------- #
msg "A instalar dependências e Geekbench 6 dentro do LXC..."
pct exec "$CTID" -- bash -lc "
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y wget tar ca-certificates libc6 libstdc++6

mkdir -p /opt/geekbench
cd /opt/geekbench
wget -q \"https://cdn.geekbench.com/Geekbench-${GEEK_VER}-Linux.tar.gz\" -O geekbench.tar.gz
tar -xzf geekbench.tar.gz
ln -sf \"/opt/geekbench/Geekbench-${GEEK_VER}-Linux/geekbench6\" /usr/local/bin/geekbench6
"

ok "Geekbench 6 instalado."

# -----------------------------[ Run benchmark ]------------------------------ #
msg "A correr benchmark..."
if [[ "$UPLOAD" == "1" ]]; then
  pct exec "$CTID" -- bash -lc "
set -e
geekbench6 | tee /root/geekbench-result.txt
"
else
  pct exec "$CTID" -- bash -lc "
set -e
geekbench6 --no-upload | tee /root/geekbench-result.txt
"
fi

ok "Benchmark concluído."

echo
echo -e "${BOLD}Resultados:${CL}"
echo "  - Ficheiro no LXC: /root/geekbench-result.txt"
echo "  - Ver no host: pct exec $CTID -- cat /root/geekbench-result.txt"
echo
echo -e "${BL}Dica:${CL} se quiseres guardar no host:"
echo "  pct exec $CTID -- cat /root/geekbench-result.txt > geekbench-${CTID}.txt"
echo
ok "Done."
``
