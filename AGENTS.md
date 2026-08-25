# AGENTS.md — AdGuard Home + Unbound Installer

**Purpose**: Installer for AdGuard Home + Unbound DNS stack on Proxmox LXC (Alpine Linux with OpenRC + apk). Docs & output are French; code is English.

## Entrypoints & Structure

- `install_unbound_interactive.sh` (v4.0.0) — main script. Must run as root.
  - Sources `lib/common.sh` (required; fail-fast if missing).
  - Sources `lib/health_checks.sh` (optional; degrades gracefully via `HEALTH_CHECKS_AVAILABLE` flag).
- `setup.sh` — POSIX sh bootstrap that auto-installs bootstrap dependencies via apk, downloads full repo, and invokes the main script.
- `tests/test_suite.sh` — self-contained test suite.
- `.agent/workflows/` — agent workflow markdown files for code refactoring, debugging, etc.

## Key Commands

```bash
# All modes
sudo ./install_unbound_interactive.sh --install
sudo ./install_unbound_interactive.sh --repair
sudo ./install_unbound_interactive.sh --unbound-only
sudo ./install_unbound_interactive.sh --health
sudo ./install_unbound_interactive.sh --stats
sudo ./install_unbound_interactive.sh --benchmark [n]
sudo ./install_unbound_interactive.sh --update
sudo ./install_unbound_interactive.sh --uninstall
sudo ./install_unbound_interactive.sh --dry-run --install   # simulation, no changes

# With upstream override
sudo ./install_unbound_interactive.sh --upstream quad9 --install
# Valid upstreams: cloudflare quad9 google adguard

# Tests
./tests/test_suite.sh                           # all tests
./tests/test_suite.sh --test validate_ipv4      # single test

# Lint (CI runs this exact command)
shellcheck install_unbound_interactive.sh lib/common.sh lib/health_checks.sh tests/test_suite.sh setup.sh

# Graphify (Knowledge Graph)
rtk graphify update .                           # Rebuild code graph (AST-only, no cost)
rtk graphify query "How does Unbound config work?" # Query code graph
```

## Architecture

```
Clients → AdGuard Home (:53, web :3000) → 127.0.0.1:5335 → Unbound (cache + DNSSEC + DoT) → Upstream
```

Unbound config: `/etc/unbound/unbound.conf.d/99-adguard-unbound-installer.conf`. Logs: `/var/log/adguard-unbound-installer.log`. Tuning adapts to detected CPU/RAM.

## Graphify Integration

This repository contains a **Graphify** knowledge graph at `graphify-out/`.
- **Querying**: For any questions regarding codebase architecture or relationships, use `rtk graphify query "<question>"`.
- **Explaining**: To explain a specific concept, class, or function, use `rtk graphify explain "<concept>"`.
- **Updating**: **CRITICAL** — Always run `rtk graphify update .` after modifying code files to keep the graph and `GRAPH_REPORT.md` synchronized and current (AST-only, no LLM cost).

## Gotchas

- **Blocks on Proxmox host** by default. Override: `--allow-proxmox-host` (not recommended).
- **Full repo required.** Main script fails fast if `lib/common.sh` is absent. Cannot run via raw `bash -c "$(curl ...install_unbound_interactive.sh)"` — use `setup.sh` instead.
- **Main scripts** use `set -Eeuo pipefail` with `trap cleanup EXIT` and `trap error_handler ERR`. Tests deliberately omit `set -e`.
- **`rtk` prefix** before shell commands (`rtk git status`) is the local convention — enforced by `.github/copilot-instructions.md` and the `rtk-rewrite.json` hook.
- **CI** runs `shellcheck` + `bash tests/test_suite.sh` on push/PR to `main` (`.github/workflows/ci.yml`). No build step, no Makefile.
- **Test `--test` values** map to `test_*` function names via a `case` switch: `validate_ipv4`, `validate_port`, `system_requirements`, `disk_space_check`, `power_of_two`, `power_of_two_edge`, `count_cpuset_cpus`, `performance_profile_boundaries`, `validate_ipv4_edge`, `atomic_write`, `performance_defaults`.
- **Commits** follow Conventional Commits (`feat:`, `fix:`, `perf:`, `chore:`, `docs:`, `refactor:`, `test:`).
- **`docs/` directory** is referenced in `CONTRIBUTING.md` but does not exist in the repo.
