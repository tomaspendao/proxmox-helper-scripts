# Network Optimizer for UniFi – Deploy automático em Proxmox

Este script cria um LXC **unprivileged** Debian 13 (fallback 12) em Proxmox VE e faz o deploy do [Network Optimizer for UniFi](https://github.com/Ozark-Connect/NetworkOptimizer) (Ozark Connect) com Docker Compose dentro do container.

O objetivo é ter uma ferramenta de **auditoria e medição** da rede UniFi (auditoria de DNS/VLAN/firewall, Wi-Fi, speedtest LAN/WAN com tracing L2, estatísticas de ONT/SFP), instalada de forma simples, repetível e com a versão fixada.

Licença do Network Optimizer: Business Source License 1.1 (gratuito para uso pessoal até 3 sites).

## O que este script faz

- Deteta automaticamente:
  - Storage com suporte a templates LXC (`vztmpl`)
  - Template Debian 13 mais recente (fallback para Debian 12)
  - Próximo CTID/VMID livre
- Cria um LXC **unprivileged** com:
  - `nesting=1` por defeito (compatível com o token do Terraform, ADR-005)
  - `nesting=1,keyctl=1` como opção de fallback
  - VLAN tag, IP estático e DNS configuráveis
  - tags `network;docker`
- Instala o Docker CE e o `docker compose` (plugin v2) a partir do repositório oficial da Docker
- Faz um teste de fumo do Docker (`docker run hello-world`) antes de instalar a app
- Cria a stack em `/opt/network-optimizer`, baseada no `docker-compose.prod.yml` oficial, com:
  - imagens `ghcr.io/ozark-connect/network-optimizer` e `ghcr.io/ozark-connect/speedtest` com a **versão fixada** (`NETOPT_VERSION`)
  - `.env` com `TZ`, `HOST_IP` e as restantes opções (permissões `0600`)
  - volumes persistentes `data/` (SQLite, chave de cifra das credenciais), `ssh-keys/` e `logs/`
- Espera que o contentor fique `healthy` e mostra a password inicial do utilizador `admin`

## Arquitetura final

```
Proxmox VE
└─ LXC unprivileged (Debian 13, nesting=1)
   └─ Docker
      ├─ network-optimizer            (host network, :8042)
      └─ network-optimizer-speedtest  (OpenSpeedTest, :3005)
```

## Utilização

No shell do nó Proxmox:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/network-optimizer/create-network-optimizer-lxc.sh)"
```

Para fixar outra versão da app:

```bash
NETOPT_VERSION=2.10.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/network-optimizer/create-network-optimizer-lxc.sh)"
```

## Defaults

| Opção | Valor |
|---|---|
| Hostname | `netopt` |
| CPU / RAM / swap / disco | 2 cores / 2048 MB / 512 MB / 10 GB |
| Bridge / VLAN | `vmbr0` / `10` |
| IP / gateway | `10.10.10.61/24` / `10.10.10.1` |
| DNS | `192.168.50.119 192.168.50.120` |
| Timezone | `Europe/Lisbon` |

## Portas

| Porta | Serviço |
|---|---|
| 8042/tcp | Web UI e API (`/api/health`) |
| 3005/tcp | Speedtest no browser (OpenSpeedTest) |
| 5201/tcp | Servidor iperf3 (desligado por defeito, `IPERF3_SERVER_ENABLED`) |
| 8043/tcp | Túnel dos On-Site Agents (só multi-site; não expor) |

## Depois da instalação

1. Abrir `http://<IP>:8042` e entrar com `admin` e a password mostrada no fim do script. Para a ver de novo:
   ```bash
   pct exec <CTID> -- bash -c "docker logs network-optimizer 2>&1 | grep -A5 'AUTO-GENERATED'"
   ```
2. Mudar a password em **Settings > Admin Password**.
3. No UniFi, criar uma conta **Local Access Only** dedicada, com **Network: View Only**, **Protect: View Only** e **User & Account Management: None**. Contas Ubiquiti SSO não funcionam.
4. O SSH ao gateway e aos dispositivos só é preciso para o Adaptive SQM e os speedtests a partir do gateway/dispositivos. A auditoria de segurança, o Config Optimizer e o Wi-Fi Optimizer funcionam sem SSH.

## Atualizar

```bash
pct exec <CTID> -- bash -c 'cd /opt/network-optimizer && sed -i "s/^NETOPT_VERSION=.*/NETOPT_VERSION=<nova>/" .env && docker compose pull && docker compose up -d && docker image prune -f'
```

## Segurança

- A pasta `data/` contém a chave que cifra as credenciais guardadas (UniFi, SSH). Quem tiver uma cópia de `data/` (incluindo backups) consegue decifrá-las. Os exports `.nopt` também a incluem.
- Restringir o acesso a 8042/3005 à LAN/VPN (políticas da firewall do gateway ou firewall do Proxmox).
- As funcionalidades que escrevem no gateway (Automatic Blocking, aplicar canais, Firmware Rollout, agent no gateway) devem ficar desligadas até decisão explícita.
