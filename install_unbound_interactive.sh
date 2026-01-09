#!/usr/bin/env bash

# ==========================================================================
# AdGuard Home & Unbound All-in-One Installer/Updater pour Proxmox LXC
# ==========================================================================
# Script inspiré du style "Proxmox VE Helper-Scripts" (tteck/community-scripts)
# Installe, configure et met à jour AdGuard Home + Unbound sur Debian/Ubuntu LXC.
# ==========================================================================
# Auteur: Nicolas (Optimisé par Context7 Agent)
# Version: 3.0.0 (Optimized)
# Licence: MIT
# ==========================================================================

# --- Safety & Error Handling ---
set -Eeuo pipefail
trap cleanup EXIT
trap 'error_handler $? $LINENO $BASH_COMMAND' ERR

# --- Global# IMPERATIVE: Stability Release
# Version: 3.2.4 (Stats Display Fix)
readonly SCRIPT_VERSION="3.2.4"
readonly LOG_FILE="/var/log/adguard-unbound-installer.log"

# App
readonly APP="AdGuard Home & Unbound"
readonly UNBOUND_PORT=5335
readonly AGH_INSTALL_DIR="/opt/AdGuardHome"
readonly AGH_BINARY="${AGH_INSTALL_DIR}/AdGuardHome"
readonly AGH_YAML="${AGH_INSTALL_DIR}/AdGuardHome.yaml"
readonly AGH_SERVICE="AdGuardHome"

# Colors
readonly YW="\033[33m"
readonly BL="\033[34m"
readonly RD="\033[01;31m"
readonly GN="\033[1;32m"
readonly CL="\033[m"
readonly BFR="\\r\\033[K"
readonly HOLD="-"
readonly CM="${GN}✓${CL}"
readonly CROSS="${RD}✗${CL}"
readonly INFO="${BL}ℹ${CL}"
readonly WARN="${YW}⚠${CL}"

# Global State Variables (mutable)
AGH_ALREADY_INSTALLED=false
UNBOUND_ALREADY_INSTALLED=false
INTERACTIVE=true
SELECTED_UPSTREAM="cloudflare"
CPU_CORES=1
RAM_MB=512

# --- Error Handling & Cleanup ---

cleanup() {
    # Clean up temp directories if they exist
    rm -rf /tmp/agh_install /tmp/agh_update 2>/dev/null || true
}

error_handler() {
    local exit_code="$1"
    local line_number="$2"
    local command="$3"
    msg_error "Erreur détectée ligne ${line_number}: commande '${command}' a échoué (code ${exit_code})"
}

# --- Logging & UI Functions ---

spinner() {
    local chars="/-\|"
    local pid=$!
    while kill -0 $pid 2>/dev/null; do
        for (( i=0; i<${#chars}; i++ )); do
            sleep 0.1
            echo -en "${BFR}${HOLD} ${chars:$i:1}"
        done
    done
    echo -en "${BFR}"
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

msg_info() {
    local msg="$1"
    echo -ne " ${HOLD} ${YW}${msg}...${CL}"
    log "INFO: $msg"
}

msg_ok() {
    local msg="$1"
    echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
    log "OK: $msg"
}

msg_error() {
    local msg="$1"
    echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
    log "ERROR: $msg"
}

msg_warn() {
    local msg="$1"
    echo -e "${BFR} ${WARN} ${YW}${msg}${CL}"
    log "WARN: $msg"
}

header_info() {
    clear
    cat <<"EOF"
    ___       __  ______                     __   __  __                     
   /   | ____/ / / ____/_  ______ __________/ /  / / / /___  ____ ___  ___   
  / /| |/ __  / / / __/ / / / __ `/ ___/ __  /  / /_/ / __ \/ __ `__ \/ _ \  
 / ___ / /_/ / / /_/ / /_/ / /_/ / /  / /_/ /  / __  / /_/ / / / / / /  __/  
/_/  |_\__,_/  \____/\__,_/\__,_/_/   \__,_/  /_/ /_/\____/_/ /_/ /_/\___/   
                                        & Unbound DNS Optimizer
                                        v3.0.0 (High Performance)
EOF
    echo -e "${BL}====================================================================${CL}"
    echo -e "${GN}   AdGuard Home + Unbound :: Installation & Tuning${CL}"
    echo -e "${BL}====================================================================${CL}"
    echo ""
}

# --- System Checks ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "Ce script doit être exécuté en tant que root."
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            msg_error "Ce script est conçu pour Debian ou Ubuntu. OS détecté: $ID"
            exit 1
        fi
    else
        msg_error "Impossible de détecter l'OS."
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "tar" "jq" "whiptail" "bc" "python3")
    local missing_deps=()
    local python_packages=("python3-yaml")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check for python3-yaml specifically
    if ! dpkg -s python3-yaml &>/dev/null && ! python3 -c "import yaml" &>/dev/null; then
         missing_deps+=("python3-yaml")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        msg_info "Installation des dépendances manquantes: ${missing_deps[*]}"
        apt-get update &>/dev/null
        apt-get install -y "${missing_deps[@]}" &>/dev/null
        msg_ok "Dépendances installées"
    fi
}

# --- Network Optimization (Sysctl) ---

apply_sysctl_tuning() {
    msg_info "Application des optimisations réseau (sysctl)"
    
    local SYSCTL_CONF="/etc/sysctl.d/99-dns-optimization.conf"
    
    # Values tuned for high-throughput UDP (DNS)
    cat > "$SYSCTL_CONF" <<EOF
# Optimisations DNS (Généré par Installer v${SCRIPT_VERSION})
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 50000
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
EOF
    
    # Try to apply, handle container limitations gracefully
    if sysctl -p "$SYSCTL_CONF" &>/dev/null; then
        msg_ok "Optimisations sysctl appliquées"
    else
        msg_warn "Optimisations sysctl non appliquées (LXC non-privilégié ?)"
    fi
}

# --- Unbound Logic & Calculation ---

# Helper to find nearest power of 2 (round down)
get_power_of_two() {
    local n=$1
    local p=1
    while (( p * 2 <= n )); do
        (( p *= 2 ))
    done
    echo $p
}

get_system_resources() {
    CPU_CORES=$(nproc --all)
    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
}

calculate_optimized_settings() {
    get_system_resources
    
    # Allow manual override in interactive mode
    if [[ "$INTERACTIVE" == "true" ]]; then
        if ! whiptail --title "Ressources Système" --yesno "Détecté : ${CPU_CORES} CPU, ${RAM_MB} MB RAM.\n\nUtiliser ces valeurs pour l'auto-configuration ?" 10 60; then
             # Manual Input with Cancel handling
             local user_cpu
             if user_cpu=$(whiptail --inputbox "Nombre de coeurs CPU :" 8 40 "$CPU_CORES" 3>&1 1>&2 2>&3); then
                 CPU_CORES=$user_cpu
             else
                 msg_warn "Saisie annulée. Utilisation de la valeur détectée ($CPU_CORES)."
             fi
             
             local user_ram
             if user_ram=$(whiptail --inputbox "RAM en MB :" 8 40 "$RAM_MB" 3>&1 1>&2 2>&3); then
                 RAM_MB=$user_ram
             else
                 msg_warn "Saisie annulée. Utilisation de la valeur détectée ($RAM_MB)."
             fi
        fi
    fi

    # Unbound Threading & Slabs (Performance Critical)
    # Docs: Slabs reduce lock contention. Must be power of 2. Close to num_cpus is ideal.
    NUM_THREADS=$CPU_CORES
    
    # Calculate Slabs: Power of 2, closest to threads but max 8-16 usually sufficient
    if (( CPU_CORES == 1 )); then
        CACHE_SLABS=1 # Special case for single core to save memory
        NUM_THREADS=1
    else
        # Find nearest power of 2 (e.g., 6 cores -> 4 slabs)
        CACHE_SLABS=$(get_power_of_two $CPU_CORES)
        # Ensure at least 2 slabs if >1 core
        (( CACHE_SLABS < 2 )) && CACHE_SLABS=2
    fi

    # Memory Allocation Logic (Tiered)
    if (( RAM_MB < 512 )); then
        # Micro Instance
        RRSET_CACHE_SIZE="16m"
        MSG_CACHE_SIZE="8m"
        SO_RCVBUF="1m"
        SO_SNDBUF="1m"
        INFRA_HOSTS=200
        OUTGOING_RANGE=512
        QUERIES_PER_THREAD=512
        NEG_CACHE_SIZE="1m"
    elif (( RAM_MB < 1024 )); then
        # Small (Pi 4 / Standard LXC)
        RRSET_CACHE_SIZE="64m"
        MSG_CACHE_SIZE="32m"
        SO_RCVBUF="2m"
        SO_SNDBUF="2m"
        INFRA_HOSTS=10000
        OUTGOING_RANGE=2048
        QUERIES_PER_THREAD=1024
        NEG_CACHE_SIZE="4m"
    elif (( RAM_MB < 4096 )); then
        # Medium/High (Common Server)
        RRSET_CACHE_SIZE="256m"
        MSG_CACHE_SIZE="128m"
        SO_RCVBUF="4m"
        SO_SNDBUF="4m"
        INFRA_HOSTS=50000
        OUTGOING_RANGE=8192
        QUERIES_PER_THREAD=4096
        NEG_CACHE_SIZE="32m"
    else
        # Premium/Dedibox (> 4GB)
        RRSET_CACHE_SIZE="512m"
        MSG_CACHE_SIZE="256m"
        SO_RCVBUF="8m"
        SO_SNDBUF="8m"
        INFRA_HOSTS=100000
        OUTGOING_RANGE=8192
        QUERIES_PER_THREAD=8192
        NEG_CACHE_SIZE="64m"
    fi
}

install_unbound() {
    if systemctl is-active --quiet unbound 2>/dev/null; then
        msg_warn "Unbound est déjà actif (sera reconfiguré)"
    else
        msg_info "Installation du paquet Unbound"
        apt-get install -y unbound ca-certificates dnsutils &>/dev/null
        msg_ok "Unbound installé"
    fi

    # Disable systemd-resolved if conflict
    if systemctl is-active --quiet systemd-resolved; then
         if ss -tulnp | grep -E ':(53|5353)\s' | grep -q 'systemd-resolve'; then
            msg_info "Désactivation de systemd-resolved (conflit port 53)"
            systemctl disable --now systemd-resolved.service &>/dev/null || true
            rm -f /etc/resolv.conf
            msg_ok "systemd-resolved désactivé"
         fi
    fi

    # Generate Config
    calculate_optimized_settings
    
    # Backup
    if [[ -f "/etc/unbound/unbound.conf" ]]; then
        mv "/etc/unbound/unbound.conf" "/etc/unbound/unbound.conf.backup.$(date +%s)"
    fi

    msg_info "Génération de la configuration Unbound (Threads: $NUM_THREADS, Slabs: $CACHE_SLABS)"
    
    cat > /etc/unbound/unbound.conf <<EOF
server:
    verbosity: 1
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    
    # --- Performance Tuning (Context7 Optimized) ---
    num-threads: ${NUM_THREADS}
    
    # Slabs (Power of 2 to reduce lock contention)
    msg-cache-slabs: ${CACHE_SLABS}
    rrset-cache-slabs: ${CACHE_SLABS}
    infra-cache-slabs: ${CACHE_SLABS}
    key-cache-slabs: ${CACHE_SLABS}
    
    # Cache Sizes
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    msg-cache-size: ${MSG_CACHE_SIZE}
    neg-cache-size: ${NEG_CACHE_SIZE}
    
    # Network Buffers
    so-reuseport: yes
    so-rcvbuf: ${SO_RCVBUF}
    so-sndbuf: ${SO_SNDBUF}
    edns-buffer-size: 1232
    max-udp-size: 1232
    
    # Limits
    outgoing-range: ${OUTGOING_RANGE}
    num-queries-per-thread: ${QUERIES_PER_THREAD}
    infra-cache-numhosts: ${INFRA_HOSTS}
    
    # Privacy & Security
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-algo-downgrade: yes
    use-caps-for-id: yes
    private-address: 192.168.0.0/16
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    
    # Prefetching
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400

    # Certs
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

forward-zone:
    name: "."
    forward-tls-upstream: yes
    $(get_upstream_forward_lines)

remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/etc/unbound/unbound_server.key"
    server-cert-file: "/etc/unbound/unbound_server.pem"
    control-key-file: "/etc/unbound/unbound_control.key"
    control-cert-file: "/etc/unbound/unbound_control.pem"
EOF

    # Root Hints
    wget -q -O /usr/share/dns/root.hints https://www.internic.net/domain/named.cache 2>/dev/null || true

    # Setup Control Keys
    if [[ ! -f "/etc/unbound/unbound_server.key" ]]; then
        msg_info "Génération des clés de contrôle Unbound"
        unbound-control-setup &>/dev/null || true
    fi
    
    # Fix Permissions (Critical for functionality)
    chown -R unbound:unbound /etc/unbound
    chmod 755 /etc/unbound
    chmod 640 /etc/unbound/unbound_control.*

    # Check & Start
    if unbound-checkconf &>/dev/null; then
        systemctl restart unbound
        systemctl enable unbound &>/dev/null
        msg_ok "Configuration Unbound valide et service démarré"
    else
        msg_error "Configuration Unbound invalide !"
        unbound-checkconf
        exit 1
    fi
}

get_upstream_forward_lines() {
    # Helper to print forward-addr lines
    if [[ "$SELECTED_UPSTREAM" == "cloudflare" ]]; then
        echo "forward-addr: 1.1.1.1@853#cloudflare-dns.com"
        echo "    forward-addr: 1.0.0.1@853#cloudflare-dns.com"
    elif [[ "$SELECTED_UPSTREAM" == "quad9" ]]; then
        echo "forward-addr: 9.9.9.9@853#dns.quad9.net"
        echo "    forward-addr: 149.112.112.112@853#dns.quad9.net"
    else
         echo "forward-addr: 1.1.1.1@853#cloudflare-dns.com"
    fi
}

# --- AdGuard Home Logic ---

configure_adguard_upstream() {
    if [[ ! -f "$AGH_YAML" ]]; then
        return 0
    fi

    msg_info "Vérification de la configuration AdGuard Home..."
    
    # Check if already using Unbound
    if grep -q "127.0.0.1:${UNBOUND_PORT}" "$AGH_YAML"; then
        msg_ok "AdGuard Home utilise déjà Unbound"
        return 0
    fi

    msg_info "Configuration d'AdGuard Home pour utiliser Unbound (Optimisation)"
    
    # Backup
    cp "$AGH_YAML" "${AGH_YAML}.backup.$(date +%s)"
    
    # Modify YAML (Python method preferred for safety)
    if command -v python3 &>/dev/null; then
        python3 <<PYTHON
import yaml
import sys

try:
    with open("$AGH_YAML", 'r') as f:
        config = yaml.safe_load(f)
    
    if 'dns' not in config:
        config['dns'] = {}
    
    # Set Unbound as unique upstream
    config['dns']['upstream_dns'] = ['127.0.0.1:${UNBOUND_PORT}']
    
    # Examples for bootstrap
    config['dns']['bootstrap_dns'] = ['1.1.1.1', '9.9.9.9']
    
    with open("$AGH_YAML", 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print("OK")
except Exception as e:
    sys.exit(1)
PYTHON
    else
        # Fallback SED
        sed -i "s|^  - https://dns10.quad9.net/dns-query|  - 127.0.0.1:${UNBOUND_PORT}|" "$AGH_YAML" 2>/dev/null || true
    fi
    
    systemctl restart AdGuardHome
    msg_ok "AdGuard Home reconfiguré pour utiliser Unbound"
}

install_adguard_home() {
    if [[ -f "$AGH_BINARY" ]]; then
         msg_info "AdGuard Home déjà installé"
         # Even if installed, we want to ensure config is optimized
         configure_adguard_upstream
         return 0
    fi
    
    msg_info "Installation AdGuard Home..."
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) AGH_ARCH="amd64" ;;
        aarch64) AGH_ARCH="arm64" ;;
        armv7l) AGH_ARCH="armv7" ;;
        *) msg_error "Arch $ARCH non supportée"; exit 1 ;;
    esac
    
    LATEST_VER=$(curl -fsSL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | jq -r '.tag_name')
    if [[ -z "$LATEST_VER" ]]; then
        msg_error "Impossible de trouver la dernière version"
        exit 1
    fi
    
    local url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VER}/AdGuardHome_linux_${AGH_ARCH}.tar.gz"
    
    mkdir -p /tmp/agh_install
    wget -qO /tmp/agh_install/AGH.tar.gz "$url"
    tar -xzf /tmp/agh_install/AGH.tar.gz -C /tmp/agh_install
    
    mkdir -p "$AGH_INSTALL_DIR"
    mv /tmp/agh_install/AdGuardHome/AdGuardHome "$AGH_BINARY"
    chmod +x "$AGH_BINARY"
    
    # Service
    "$AGH_BINARY" -s install &>/dev/null || true
    systemctl start AdGuardHome
    
    # Wait for YAML
    msg_info "Initialisation..."
    sleep 5
    
    if [[ -f "$AGH_YAML" ]]; then
        configure_adguard_upstream
        msg_ok "AdGuard Home installé et lié à Unbound"
    else
        msg_warn "Fichier YAML non trouvé, config manuelle requise"
    fi
}

# --- Uninstall Logic ---

uninstall_all() {
    if ! whiptail --title "Désinstallation" --yesno "Voulez-vous vraiment désinstaller AdGuard Home et Unbound ?\nCela supprimera les fichiers de configuration et les données." 10 60; then
        return 0
    fi
    
    msg_info "Suppression AdGuard Home..."
    systemctl stop AdGuardHome &>/dev/null || true
    "$AGH_BINARY" -s uninstall &>/dev/null || true
    rm -rf "$AGH_INSTALL_DIR"
    msg_ok "AdGuard Home supprimé"
    
    msg_info "Suppression Unbound..."
    systemctl stop unbound &>/dev/null || true
    apt-get remove --purge -y unbound &>/dev/null
    rm -rf /etc/unbound
    msg_ok "Unbound supprimé"
    
    msg_ok "Désinstallation terminée"
    exit 0
}

# --- Main Menus ---

select_upstream() {
    local choice
    choice=$(whiptail --title "DNS Upstream" --menu "Choisir le fournisseur DoT :" 15 60 4 \
        "1" "Cloudflare (Rapide)" \
        "2" "Quad9 (Sécurisé)" \
        3>&1 1>&2 2>&3) || return 0
        
    case $choice in
        1) SELECTED_UPSTREAM="cloudflare" ;;
        2) SELECTED_UPSTREAM="quad9" ;;
    esac
}

update_script() {
    msg_info "Vérification de la mise à jour du script..."
    local remote_url="https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/install_unbound_interactive.sh"
    local local_file="$0"
    
    # Download content specifically to check version/diff (simple overwrite for now is safer to avoid complexity)
    if curl -fsSL "$remote_url" -o "${local_file}.tmp"; then
        chmod +x "${local_file}.tmp"
        mv "${local_file}.tmp" "$local_file"
        msg_ok "Script mis à jour ! Relancez-le."
        exit 0
    else
        msg_error "Échec du téléchargement de la mise à jour."
        rm -f "${local_file}.tmp"
    fi
}

show_menu() {
    local choice
    while true; do
        choice=$(whiptail --title "Menu (v${SCRIPT_VERSION})" --menu "Choisir une action:" 18 50 7 \
            "1" "Installer" \
            "2" "Reparer" \
            "3" "MAJ Systeme" \
            "4" "MAJ Script" \
            "5" "Stats" \
            "6" "Desinstaller" \
            "7" "Quitter" \
            3>&1 1>&2 2>&3) || exit 0

        case $choice in
            1)
                select_upstream
                apply_sysctl_tuning
                install_unbound
                install_adguard_home
                whiptail --msgbox "Installation terminée !\nURL: http://$(hostname -I | awk '{print $1}'):3000" 10 60
                ;;
            2)
                select_upstream
                install_unbound # Re-runs config generation
                whiptail --msgbox "Optimisation appliquée avec succès." 8 50
                ;;
            3)
                msg_info "Mise à jour OS..."
                apt-get update && apt-get upgrade -y
                msg_ok "OS à jour"
                ;;
            4)
                update_script
                ;;
            5)
                if command -v unbound-control &>/dev/null; then
                    local stats_file=$(mktemp)
                    if unbound-control stats_noreset > "$stats_file" 2>&1; then
                        if [[ -s "$stats_file" ]]; then
                            whiptail --title "Stats Unbound" --scrolltext --textbox "$stats_file" 20 70
                        else
                            whiptail --msgbox "Pas de stats disponibles.\nUnbound vient peut-etre de demarrer." 10 50
                        fi
                    else
                        whiptail --msgbox "Erreur unbound-control:\n$(cat $stats_file)" 12 60
                    fi
                    rm -f "$stats_file"
                else
                    msg_error "unbound-control non trouve"
                fi
                ;;
            6)
                uninstall_all
                ;;
            7)
                exit 0
                ;;
        esac
    done
}

# --- Entry Point ---

main() {
    check_root
    check_os
    check_dependencies
    
    if [[ "${1:-}" == "--install" ]]; then
        INTERACTIVE=false
        apply_sysctl_tuning
        install_unbound
        install_adguard_home
    elif [[ "${1:-}" == "--uninstall" ]]; then
        uninstall_all
    else
        show_menu
    fi
}

main "$@"
