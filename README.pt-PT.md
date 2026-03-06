
---

# 2) `README.pt-PT.md` (root – PT‑PT)

```md
# Proxmox Helper Scripts

Scripts com menus para instalar serviços comuns em **Proxmox VE** usando **LXC**, com filosofia de segurança **LAN/VPN-first**.

📘 English: README.md

---

## Scripts disponíveis

- **code-server** — VS Code no browser num LXC Debian 12.

Cada script inclui documentação na sua pasta.

---

## Funcionalidades

- Containers LXC unprivileged por defeito
- Deteção automática de:
  - Storage de templates com `vztmpl`
  - Template Debian 12 mais recente disponível
  - Próximo CTID/VMID livre
- Configuração via menus (`whiptail`)
- Pensado para acesso via LAN/VPN (não para expor à Internet)

---

## Requisitos

- Proxmox VE 8.x+ / 9.x+
- Acesso à internet no host Proxmox
- `whiptail` instalado no host Proxmox

Instalar no host Proxmox:

```bash
apt update && apt install -y whiptail
