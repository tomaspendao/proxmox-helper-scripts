# code-server LXC for Proxmox

Deploy **code-server** (Visual Studio Code in the browser) inside a **Debian 12 LXC** on **Proxmox VE**.

This script is menu-driven and designed for **LAN/VPN-first** usage, following common homelab and small infrastructure best practices.

---

## What this script does

- Automatically detects a storage that supports LXC templates (`vztmpl`)
- Automatically selects the **latest available Debian 12** LXC template
- Automatically selects the **next free CTID/VMID**
- Creates an **unprivileged LXC container**
- Installs **code-server** using the official installer
- Creates a **non-root Linux user** to run the service
- Writes the code-server configuration file
- Enables and starts the `systemd` service (`code-server@user`)

---

## Network model

- Default: **DHCP**
- Optional: Static IP (via menu)
- Bind address options:
  - `0.0.0.0` → LAN / VPN access (recommended)
  - `127.0.0.1` → reverse proxy or SSH tunnel

---

## Usage

Run directly on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/code-server/create-code-server-lxc.sh)"
