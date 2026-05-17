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

fetch_remote_sha() {
    local repo="$1" ref="$2"
    local api_url="https://api.github.com/repos/${repo}/git/ref/heads/${ref}"
    local sha
    sha=$(curl -fsSL --max-time 5 "$api_url" 2>/dev/null | jq -r '.object.sha' 2>/dev/null) || return 0
    if [[ -n "$sha" && "$sha" != "null" ]]; then
        echo "Commit distant: ${sha:0:7}"
    fi
}

main() {
    need_cmd curl
    need_cmd tar

    local tarball="${WORKDIR}/repo.tar.gz"

    echo "Téléchargement de ${REPO}@${REF}..."
    curl -fsSL "$ARCHIVE_URL" -o "$tarball"

    local sha256
    sha256=$(sha256sum "$tarball" | awk '{print $1}')
    echo "SHA256: ${sha256}"

    if command -v jq &>/dev/null; then
        fetch_remote_sha "${REPO}" "${REF}" 2>/dev/null || true
    fi

    echo "Vérification de l'archive..."
    tar -tzf "$tarball" >/dev/null 2>&1 || error "Archive corrompue ou invalide."

    tar -xzf "$tarball" -C "$WORKDIR" --strip-components=1
    rm -f "$tarball"

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
