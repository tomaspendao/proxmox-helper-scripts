# Changelog
All notable changes to this project will be documented in this file.

The format is based on **Keep a Changelog**,
and this project adheres to **Semantic Versioning**.

---

## [Unreleased]
### Added
- Placeholder for upcoming improvements and new helper scripts.

---

## [1.0.3] - 2026-03-06
### Added
- Automatic detection of the **latest Debian 12 LXC template** using `pveam available`.
- Improved robustness when template names change upstream.

### Fixed
- `pveam download` failures caused by outdated hard‑coded template filenames.

---

## [1.0.2] - 2026-03-06
### Added
- **Automatic CTID/VMID detection** using `pvesh get /cluster/nextid` with fallback logic.
- Clear output showing the selected CTID/VMID during execution.
- Script version output at startup for easier troubleshooting.

### Fixed
- CTID collisions when a manually chosen ID already existed.

---

## [1.0.1] - 2026-03-06
### Added
- **Automatic detection of storage** supporting LXC templates (`vztmpl`).

### Fixed
- Failure when downloading templates to storages without `vztmpl` enabled.

---

## [1.0.0] - 2026-03-06
### Added
- Initial public release.
- Menu‑driven deployment of **code-server** in a Debian 12 LXC.
- Unprivileged LXC configuration.
- DHCP by default, static IP optional.
- systemd service management (`code-server@user`).
- LAN/VPN‑first security model.

---

[Unreleased]: https://github.com/tomaspendao/proxmox-helper-scripts/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/tomaspendao/proxmox-helper-scripts/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/tomaspendao/proxmox-helper-scripts/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/tomaspendao/proxmox-helper-scripts/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/tomaspendao/proxmox-helper-scripts/releases/tag/v1.0.0
