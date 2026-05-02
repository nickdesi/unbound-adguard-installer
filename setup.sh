#!/usr/bin/env bash

# Bootstrap installer for AdGuard Home + Unbound on Proxmox LXC.
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)" -- --upstream quad9 --install

set -Eeuo pipefail

REPO="${REPO:-nickdesi/unbound-adguard-installer}"
REF="${REF:-main}"
WORKDIR="$(mktemp -d /tmp/unbound-adguard-installer.XXXXXX)"
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"

cleanup() {
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Commande requise introuvable: $1"
}

main() {
    need_cmd curl
    need_cmd tar

    echo "Téléchargement de ${REPO}@${REF}..."
    curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$WORKDIR" --strip-components=1

    cd "$WORKDIR"
    chmod +x ./install_unbound_interactive.sh

    if [[ $EUID -eq 0 ]]; then
        ./install_unbound_interactive.sh "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo ./install_unbound_interactive.sh "$@"
    else
        error "Exécutez ce bootstrap en root ou installez sudo."
    fi
}

main "$@"
