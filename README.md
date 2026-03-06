# Proxmox Helper Scripts

Menu-driven helper scripts to deploy common services in **Proxmox VE** using **LXC**, with **LAN/VPN-first** security defaults.

📘 Portuguese (PT-PT): [README.pt-PT.md](README.pt-PT.md)

---

## Available scripts

- **code-server**: Deploy VS Code in the browser inside a Debian 12 LXC

See each script folder for detailed documentation.

---

## Requirements

- Proxmox VE 8.x+ / 9.x+
- Internet access from the Proxmox host (to download LXC template and install packages)
- `whiptail` installed on the Proxmox host

Install `whiptail`:
```bash
apt update && apt install -y whiptail
