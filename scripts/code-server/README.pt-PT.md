# code-server LXC para Proxmox

Instala o **code-server** (Visual Studio Code no browser) num **LXC Debian 12** no **Proxmox VE**.

Este script é baseado em menus e foi desenhado com uma abordagem **LAN/VPN‑first**, seguindo boas práticas para homelab e pequenas infraestruturas.

---

## O que este script faz

- Deteta automaticamente um storage com suporte a templates LXC (`vztmpl`)
- Seleciona automaticamente o **template Debian 12 mais recente** disponível
- Deteta automaticamente o **próximo CTID/VMID livre**
- Cria um **LXC unprivileged**
- Instala o **code-server** usando o instalador oficial
- Cria um **utilizador Linux não‑root** para executar o serviço
- Escreve o ficheiro de configuração do code-server
- Ativa e inicia o serviço `systemd` (`code-server@utilizador`)

---

## Modelo de rede

- Por defeito: **DHCP**
- Opcional: IP estático (via menu)
- Opções de bind address:
  - `0.0.0.0` → acesso via **LAN / VPN** (recomendado)
  - `127.0.0.1` → proxy reverso ou túnel SSH

---

## Utilização

Executar diretamente no host Proxmox:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/code-server/create-code-server-lxc.sh)"
