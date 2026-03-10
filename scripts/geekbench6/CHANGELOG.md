# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

---

## [1.0.0] - 2026-03-10
### Added
- Initial release of **Geekbench 6 Proxmox Helper Script**
- Menu-driven LXC creation using `whiptail`
- Automatic detection of:
  - Next free CTID/VMID (`pvesh /cluster/nextid` with fallback)
  - Storage supporting `vztmpl`
  - Latest Debian 12 LXC template via `pveam available`
- Support for DHCP and Static IP configuration
- Configurable CPU cores, RAM, SWAP and disk size
- Automatic installation of Geekbench 6 (Linux tarball)
- Option to run benchmark immediately after installation
- Benchmark results saved to `/root/geekbench-result.txt` inside the container
- Optional automatic stop of the LXC after benchmark completion

---
