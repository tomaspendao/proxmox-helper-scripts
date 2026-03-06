# RomM (ROM Manager) – Deploy automático em Proxmox

Este script cria um **LXC Debian 12** em **Proxmox VE** e faz o deploy completo do
**RomM (ROM Manager)** usando **Docker + docker‑compose** dentro do container.

O objetivo é fornecer um método **simples, repetível e seguro** para instalar o RomM
em ambientes homelab ou small infra, sem dependências manuais.

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
- Cria a stack do RomM baseada no `docker-compose.example.yml` oficial
- Gera automaticamente:
  - Password da base de dados
  - Password de root do MariaDB
  - `ROMM_AUTH_SECRET_KEY`
- Cria volumes persistentes para:
  - ROMs (`library`)
  - Assets / saves
  - Configuração (`config`)
  - Recursos / metadata
  - Redis cache
  - Base de dados MariaDB
- Inicia os serviços com `docker-compose up -d`

---

## Arquitetura final

```text
Proxmox VE
└─ LXC (Debian 12)
   └─ Docker
      ├─ romm      (rommapp/romm)
      └─ romm-db   (MariaDB)
