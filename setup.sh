#!/bin/sh

# Bootstrap installer for AdGuard Home + Unbound on Alpine Linux (Proxmox LXC).
# Usage:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)"
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)"
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)" -- --upstream quad9 --install

set -eu

REPO="${REPO:-nickdesi/unbound-adguard-installer}"
REF="${REF:-main}"
WORKDIR="$(mktemp -d /tmp/unbound-adguard-installer.XXXXXX)"
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"

cleanup() {
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

ensure_bootstrap_deps() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" = "alpine" ]; then
            missing=""
            command -v curl >/dev/null 2>&1 || missing="$missing curl"
            command -v tar >/dev/null 2>&1 || missing="$missing tar"
            command -v sha256sum >/dev/null 2>&1 || missing="$missing coreutils"
            command -v jq >/dev/null 2>&1 || missing="$missing jq"
            command -v bash >/dev/null 2>&1 || missing="$missing bash"
            if [ -n "$missing" ]; then
                echo "Installation des outils de bootstrap Alpine (${missing# })..."
                apk update -q >/dev/null 2>&1 || true
                # shellcheck disable=SC2086
                apk add --no-cache $missing >/dev/null 2>&1 || error "Échec installation des dépendances initiales via apk."
            fi
        fi
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Commande requise introuvable: $1"
}

fetch_remote_sha() {
    local_repo="$1"
    local_ref="$2"
    api_url="https://api.github.com/repos/${local_repo}/git/ref/heads/${local_ref}"
    sha=$(curl -fsSL --max-time 5 "$api_url" 2>/dev/null | jq -r '.object.sha' 2>/dev/null) || return 0
    if [ -n "$sha" ] && [ "$sha" != "null" ]; then
        short_sha=$(echo "$sha" | cut -c 1-7)
        echo "Commit distant: ${short_sha}"
    fi
}

main() {
    ensure_bootstrap_deps

    need_cmd curl
    need_cmd tar
    need_cmd sha256sum

    tarball="${WORKDIR}/repo.tar.gz"

    echo "Téléchargement de ${REPO}@${REF}..."
    curl -fsSL "$ARCHIVE_URL" -o "$tarball"

    sha256=$(sha256sum "$tarball" | awk '{print $1}')
    echo "SHA256: ${sha256}"

    if [ -n "${EXPECTED_ARCHIVE_SHA256:-}" ]; then
        if [ "$sha256" != "$EXPECTED_ARCHIVE_SHA256" ]; then
            error "Checksum inattendu: attendu ${EXPECTED_ARCHIVE_SHA256}, obtenu ${sha256}"
        fi
        echo "Checksum validé via EXPECTED_ARCHIVE_SHA256"
    else
        echo "[WARN] EXPECTED_ARCHIVE_SHA256 non défini: archive non épinglée."
    fi

    if command -v jq >/dev/null 2>&1; then
        fetch_remote_sha "${REPO}" "${REF}" 2>/dev/null || true
    fi

    echo "Vérification de l'archive..."
    tar -tzf "$tarball" >/dev/null 2>&1 || error "Archive corrompue ou invalide."

    tar -xzf "$tarball" -C "$WORKDIR" --strip-components=1
    rm -f "$tarball"

    cd "$WORKDIR"
    chmod +x ./install_unbound_interactive.sh

    if [ "$(id -u)" -eq 0 ]; then
        exec bash ./install_unbound_interactive.sh "$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo bash ./install_unbound_interactive.sh "$@"
    else
        error "Exécutez ce bootstrap en root ou installez sudo."
    fi
}

main "$@"
