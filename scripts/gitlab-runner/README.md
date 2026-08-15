# GitLab Runner LXC for Proxmox

Deploy a **self-managed GitLab Runner** (Docker executor) inside a **Debian 12 LXC** on **Proxmox VE**.

This script is menu-driven and designed for **LAN/VPN-first** usage, following common homelab and small infrastructure best practices.

---

## What this script does

- Automatically detects a storage that supports LXC templates (`vztmpl`)
- Automatically selects the **latest available Debian 12** LXC template
- Automatically selects the **next free CTID/VMID**
- Creates an **unprivileged LXC container** with `nesting=1,keyctl=1` (required for Docker-in-LXC)
- Installs **Docker** using the official convenience script
- Installs **GitLab Runner** from the official GitLab package repository
- Registers the runner against a GitLab project using the **Docker executor**
- Enables and starts the `gitlab-runner` systemd service

---

## Network model

- Bridge + VLAN tag (e.g. `vmbr0` tagged `20` for a Management VLAN)
- Default: **DHCP**
- Optional: Static IP (via menu)

---

## Runner registration

You will be prompted for:

- GitLab instance URL (e.g. `https://gitlab.com`)
- **Runner authentication token** (`glrt-...`), generated in GitLab under
  **Settings > CI/CD > Runners > New project runner**
- Runner description and tags

The token is entered interactively (masked input) and is **not stored in this script or in Git** —
it is only used once at registration time. GitLab Runner stores its own credentials locally in
`/etc/gitlab-runner/config.toml` on the container, which never leaves the LXC.

---

## Security notes

- Runner is registered as a **project runner**, not a shared/instance runner
- Docker executor runs jobs in ephemeral containers (`--docker-privileged=false`)
- Runner LXC should only have network access to what it needs (Proxmox API, target VMs via SSH) —
  do not expose it to the full LAN/VLAN indiscriminately at the firewall level

---

## Usage

Run directly on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/gitlab-runner/create-gitlab-runner-lxc.sh)"
```
