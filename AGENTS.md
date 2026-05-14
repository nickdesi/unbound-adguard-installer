# AGENTS.md — AdGuard Home + Unbound Installer

**Purpose**: Bash installer for AdGuard Home + Unbound DNS stack on Proxmox LXC (Debian/Ubuntu only). Docs & output are French; code is English.

## Entrypoints & Structure

- `install_unbound_interactive.sh` — main script (v3.4.1, 1186 lines). Must run as root.
  - Sources `lib/common.sh` (required; fail-fast if missing).
  - Sources `lib/health_checks.sh` (optional; degrades gracefully).
- `setup.sh` — bootstrap that downloads full repo via curl+tar and invokes the main script.
- `tests/test_suite.sh` — self-contained tests (mocks functions inline, never sources lib).

## Key Commands

```bash
# Install / reconfigure / health
sudo ./install_unbound_interactive.sh --install
sudo ./install_unbound_interactive.sh --repair
sudo ./install_unbound_interactive.sh --health
sudo ./install_unbound_interactive.sh --dry-run --install   # simulation, no changes

# Tests (no CI workflows exist)
./tests/test_suite.sh                           # all tests
./tests/test_suite.sh --test validate_ipv4      # single test

# Lint
shellcheck install_unbound_interactive.sh lib/common.sh lib/health_checks.sh tests/test_suite.sh

# Upstream options (valid: cloudflare quad9 google adguard)
sudo ./install_unbound_interactive.sh --upstream quad9 --install
```

## Gotchas

- **Blocks on Proxmox host** by default. Override: `--allow-proxmox-host` (not recommended).
- **Full repo required.** The main script fails fast if `lib/common.sh` is absent.
- **No CI, no build step, no Makefile.**
- **Set `-Eeuo pipefail`** with `trap` in main scripts. Tests deliberately omit `set -e`.
- **RTK prefix convention** in this repo — `.github/copilot-instructions.md` and `.claude/settings.local.json` expect `rtk` prefix before shell commands (e.g. `rtk git status`).
- `.agent/` dir contains agent workflows/scripts for code refactoring, debugging, etc.
- `.github/hooks/rtk-rewrite.json` hooks into Copilot PreToolUse.

## Architecture

```
AdGuard Home (port 53, web UI :3000) ← upstream 127.0.0.1:5335 → Unbound (cache + DNSSEC + DoT)
```

Unbound listens on `127.0.0.1:5335`. Generated config: `/etc/unbound/unbound.conf.d/99-adguard-unbound-installer.conf`. Logs: `/var/log/adguard-unbound-installer.log`.
