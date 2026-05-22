# AGENTS.md — AdGuard Home + Unbound Installer

**Purpose**: Bash installer for AdGuard Home + Unbound DNS stack on Proxmox LXC (Debian/Ubuntu only). Docs & output are French; code is English.

## Entrypoints & Structure

- `install_unbound_interactive.sh` (1415 lines, v3.4.2) — main script. Must run as root.
  - Sources `lib/common.sh` (required; fail-fast if missing).
  - Sources `lib/health_checks.sh` (optional; degrades gracefully via `HEALTH_CHECKS_AVAILABLE` flag).
- `setup.sh` — bootstrap that downloads full repo via `curl`+`tar` and invokes the main script.
- `tests/test_suite.sh` — self-contained tests (mocks functions inline, never sources lib).
- `.agent/workflows/` — agent workflow markdown files for code refactoring, debugging, etc.
- `docs/` directory referenced in `CONTRIBUTING.md` **does not exist** in the repo.

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
```

## Architecture

```
Clients → AdGuard Home (:53, web :3000) → 127.0.0.1:5335 → Unbound (cache + DNSSEC + DoT) → Upstream
```

Unbound config: `/etc/unbound/unbound.conf.d/99-adguard-unbound-installer.conf`. Logs: `/var/log/adguard-unbound-installer.log`. Tuning adapts to detected CPU/RAM.

## Gotchas

- **Blocks on Proxmox host** by default. Override: `--allow-proxmox-host` (not recommended).
- **Full repo required.** Main script fails fast if `lib/common.sh` is absent. Cannot run via raw `bash -c "$(curl ...install_unbound_interactive.sh)"` — use `setup.sh` instead.
- **Main scripts** use `set -Eeuo pipefail` with `trap cleanup EXIT` and `trap error_handler ERR`. Tests deliberately omit `set -e`.
- **`rtk` prefix** before shell commands (`rtk git status`) is the local convention — enforced by `.github/copilot-instructions.md` and the `rtk-rewrite.json` hook.
- **CI** runs `shellcheck` + `bash tests/test_suite.sh` on push/PR to `main` (`.github/workflows/ci.yml`). No build step, no Makefile.
- **Test `--test` values** map to `test_*` function names via a `case` switch: `validate_ipv4`, `validate_port`, `system_requirements`, `disk_space_check`, `power_of_two`, `power_of_two_edge`, `count_cpuset_cpus`, `performance_profile_boundaries`, `validate_ipv4_edge`, `atomic_write`, `performance_defaults`.
- **Commits** follow Conventional Commits (`feat:`, `fix:`, `perf:`, `chore:`, `docs:`, `refactor:`, `test:`).
- **`docs/` directory** is referenced in `CONTRIBUTING.md` but does not exist in the repo.

## Agent Memory (mandatory — fully autonomous, no prompting)

You MUST use agentmemory **proactively** at every stage of a session. Never wait for the user to ask.

### 1. Session start — always recall context
- Call `memory_recall` avec le sujet de la session pour retrouver le contexte des sessions passées.
- Call `memory_smart_search` avec les mêmes termes pour croiser les résultats.
- Si pas de résultats, chercher avec 2-3 termes alternatifs.
- **Ne jamais démarrer une tâche sans avoir d'abord vérifié la mémoire.**

### 2. After every bug fix — always save
Sauvegarder systématiquement avec `memory_save`:
- `type: "pattern"` (lessons/bugs) or `"decision"` (architecture)
- Inclure: what broke, why, the fix, and the context
- Tags: `bug`, `lesson-learned`, + tags techniques pertinents
- **Only `memory_save`** — `memory_lesson_save` does not exist

### 3. After every architecture decision or significant refactor — always save
Même règle qu'au point 2, avec `type: "decision"`.

### 4. After every session — verify
- Call `memory_audit` pour confirmer que tout a bien été sauvegardé.
- Si un insight a été oublié, le sauvegarder immédiatement.


