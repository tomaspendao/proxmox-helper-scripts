# Geekbench 6 LXC (Proxmox Helper Script)

Helper script para Proxmox que cria um **LXC Debian 12** e executa **Geekbench 6 (CLI)** para fazer benchmark de CPU (e componentes relevantes), guardando o output num ficheiro dentro do container.

## O que faz

- Cria um LXC **Debian 12** (unprivileged, `nesting=1`)
- Configura rede via **DHCP** (`vmbr0` por defeito)
- Instala dependências mínimas
- Faz download e instala **Geekbench 6**
- Corre benchmark e guarda resultado em:
  - `/root/geekbench-result.txt` (no LXC)

Opcionalmente, podes ativar **upload** do resultado (gera link público do Geekbench).

## Requisitos

- Proxmox VE (host)
- Acesso root no node Proxmox
- Storage para templates (por defeito: `local`)
- Storage com conteúdo `rootdir` para rootfs (por defeito: `local-lvm` se existir)

## Utilização

```bash
chmod +x create-geekbench6-lxc.sh
./create-geekbench6-lxc.sh
