# Glasshouse (lg-webos-dashboard) deploy host LXC for Proxmox

Create a small **Debian 12 LXC** on **Proxmox VE** that acts as the persistent deploy/management host for
[Glasshouse](https://github.com/rorygallagher2024/lg-webos-dashboard) — a dashboard, privacy controls and
Home Assistant (MQTT) bridge for **rooted LG webOS TVs**.

> **Important:** Glasshouse runs **on the TV itself** (port `8080`). This LXC does not run the dashboard;
> it is the "computer on the same network" the upstream `deploy.sh` expects — so installs and updates
> don't depend on whichever PC you happen to be using.

---

## What this script does

- Auto-detects template storage (`vztmpl`), latest Debian 12 template and next free CTID
- Creates an **unprivileged** LXC (1 vCPU / 512 MB / 4 GB by default)
- Installs `git`, `openssh-client`, `curl`
- Clones upstream into `/opt/glasshouse` (branch or tag selectable)
- Generates an **ed25519 SSH key** for the TV (stays inside the LXC)
- Writes `/etc/glasshouse.conf` (`TV_IP`, `REPO_REF`)
- Installs the `glasshouse` wrapper command

## Prerequisites

- The TV is **rooted** with the [Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel)
  (check the upstream [tested TVs](https://rorygallagher2024.github.io/lg-webos-dashboard/tested-tvs/) list and your firmware)
- The TV has a **static IP / DHCP reservation**
- Firewall allows LXC → TV on TCP `22` (SSH), `23` (telnet, first install only) and `8080` (dashboard)

## Usage

Run on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/glasshouse/create-glasshouse-lxc.sh)"
```

Then inside the container (`pct enter <CTID>`):

| Command | Description |
|---|---|
| `glasshouse key` | Print the SSH public key to add to the TV |
| `glasshouse deploy` | `git pull` + install/update the server on the TV (`--telnet`, `--no-persist`, `--app`, `--no-app`) |
| `glasshouse status` | Check `http://<tv-ip>:8080/api/caps` |
| `glasshouse ssh` | Root shell on the TV over SSH |
| `glasshouse pull` / `version` | Update / show the upstream clone |

## Moving the TV from telnet to SSH (recommended)

A rooted TV exposes an **unauthenticated root shell on port 23**. After the first install:

1. `glasshouse key` and append the key on the TV (via telnet):
   ```sh
   mkdir -p /home/root/.ssh && echo 'ssh-ed25519 AAAA...' >> /home/root/.ssh/authorized_keys
   chmod 700 /home/root/.ssh && chmod 600 /home/root/.ssh/authorized_keys
   ```
2. Enable SSH and disable telnet in the Homebrew Channel settings, then reboot the TV.
3. `glasshouse deploy` now uses SSH automatically.

See upstream [SECURITY.md](https://rorygallagher2024.github.io/lg-webos-dashboard/SECURITY/).

## TV configuration

`deploy.sh` seeds the TV's `config.json` **only on first install** from
`/opt/glasshouse/server/config.<tv-ip>.json` (or `config.json`). Start from `config.example.json`
to set a `token` and MQTT settings before the first deploy. Untracked config files survive `glasshouse pull`.

## Security notes

- No secrets are stored in this script or in Git; the SSH key is generated inside the LXC
- The dashboard has **no authentication by default** — set a `token`, never port-forward `8080`
- Restrict the LXC at the firewall to the TV only; it needs nothing else on the IoT VLAN
