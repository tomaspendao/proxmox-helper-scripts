# RustDesk Server OSS – Deploy automático em Proxmox

Este script cria um container em **Proxmox VE** e faz o deploy completo do
**RustDesk Server OSS** (self-hosted) usando **Docker + docker-compose**.

Referência oficial: https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/

O objetivo é fornecer um método **simples, repetível e seguro** para correr o teu próprio
servidor RustDesk (hbbs + hbbr) em ambiente homelab, sem depender de infraestrutura de terceiros.

---

## LXC ou VM?

O script cria um **LXC Debian 12** (não uma VM). Motivo: hbbs/hbbr são dois binários Rust
leves a correr em Docker — não precisam de kernel próprio, virtualização aninhada, nem
passthrough de hardware. Um LXC arranca quase instantaneamente e tem overhead residual,
seguindo o mesmo padrão dos outros scripts deste repositório (`code-server`, `romm`,
`geekbench6`). Só faria sentido usar uma VM se precisasses de isolamento ao nível do
kernel — o que não é o caso aqui.

---

## O que este script faz

- Deteta automaticamente:
  - Storage com suporte a templates LXC (`vztmpl`)
  - Template Debian 12 mais recente
  - Próximo CTID/VMID livre
- Cria um **LXC Debian 12**
- Ativa **nesting** para permitir Docker dentro do container
- Instala:
  - Docker (`docker.io`)
  - Docker Compose clássico (`docker-compose`)
- Pergunta se queres instalar o **Tailscale** dentro do LXC (recomendado):
  - Instala via script oficial (`tailscale.com/install.sh`)
  - Corre `tailscale up` interativamente — o URL de autenticação aparece no terminal,
    o script fica à espera até aprovares o dispositivo na tua conta Tailscale
- Cria a stack do RustDesk Server OSS com dois serviços:
  - **hbbs** — ID/rendezvous server
  - **hbbr** — relay server
- Usa `network_mode: host` dentro do container (recomendado pela própria documentação do
  RustDesk, por causa do NAT hole punching em UDP)
- Cria um volume persistente (`./data`) onde fica guardado o keypair (`id_ed25519` /
  `id_ed25519.pub`) — garante que a chave **não muda** entre reinícios
- Pergunta qual o endereço de relay/ID a usar:
  - **tailscale** (se instalaste o Tailscale) — usa o IP Tailscale (100.x.x.x) do LXC;
    nada precisa de ficar exposto à internet, acesso só a partir do teu tailnet
  - **auto** — o IP LAN do próprio LXC (bom para LAN/VPN)
  - **custom** — um domínio ou IP fixo à tua escolha
- No final, mostra a **chave pública** para colares no cliente RustDesk

---

## Arquitetura final

```text
Proxmox VE
└─ LXC (Debian 12)
   ├─ Tailscale (opcional, acesso remoto seguro)
   └─ Docker (network_mode: host)
      ├─ hbbs   (rustdesk/rustdesk-server) — ID/rendezvous server
      └─ hbbr   (rustdesk/rustdesk-server) — relay server
```

---

## Portas usadas

Fixas pelo protocolo do RustDesk (não mudar sem motivo):

| Serviço | TCP                   | UDP    |
|---------|-----------------------|--------|
| hbbs    | 21115, 21116, 21118   | 21116  |
| hbbr    | 21117, 21119          | —      |

Se escolheres o modo **tailscale**, estas portas nunca precisam de ser abertas na firewall
nem no router — só ficam acessíveis dentro do teu tailnet. Nos modos **auto**/**custom**
sem Tailscale, mantém tudo em LAN/VPN e evita expor diretamente à internet.

---

## Como usar

Corre no **Proxmox VE host** (não dentro de um container/VM):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tomaspendao/proxmox-helper-scripts/main/scripts/rustdesk/create-rustdesk-lxc.sh)"
```

No final, o script mostra:

- IP LAN do container (e IP Tailscale, se aplicável)
- Endereço de relay/ID configurado
- A **chave pública** do servidor
- As portas a abrir na firewall/router, se necessário

No cliente RustDesk, usa:
- **ID Server / Relay Server**: o endereço mostrado no final
- **Key**: a chave pública gerada
