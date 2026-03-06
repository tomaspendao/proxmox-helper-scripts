# Proxmox Helper Scripts

Menu-driven helper scripts to deploy common services in **Proxmox VE** using **LXC**, with **LAN/VPN-first** security defaults.

📘 Portuguese (PT-PT): README.pt-PT.md

---

## Available scripts

- **code-server** — Deploy VS Code in the browser inside a Debian 12 LXC.

Each script includes its own documentation inside its folder.

---

## Features

- Unprivileged LXC containers by default
- Automatic detection of:
  - Template storage supporting `vztmpl`
  - Latest available Debian 12 template name
  - Next free CTID/VMID
- Menu-driven configuration (`whiptail`)
- Designed for LAN/VPN use (not internet-facing)

---

## Requirements

- Proxmox VE 8.x+ / 9.x+
- Internet access from the Proxmox host
- `whiptail` installed on the Proxmox host

Install on Proxmox host:

```bash
apt update && apt install -y whiptail
