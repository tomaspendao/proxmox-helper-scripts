# Changelog

## 1.0.1
- Fix `glasshouse: command not found` in `pct exec`/`pct enter` shells (no `/usr/local/bin` in PATH): symlink wrapper to `/usr/bin/glasshouse`
- Fix empty `Upstream:` line in final summary

## 1.0.0
- Initial release: Debian 12 LXC deploy host for Glasshouse (lg-webos-dashboard), SSH key generation, `glasshouse` wrapper
