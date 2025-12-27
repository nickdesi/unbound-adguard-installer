#!/usr/bin/env bash

# ==========================================================================
# AdGuard Home & Unbound All-in-One Installer/Updater pour Proxmox LXC
# ==========================================================================
# Script inspiré du style "Proxmox VE Helper-Scripts" (tteck/community-scripts)
# Installe, configure et met à jour AdGuard Home + Unbound sur Debian/Ubuntu LXC.
# ==========================================================================
# Auteur: Nicolas (basé sur les travaux de tteck)
# Licence: MIT
# ==========================================================================

set -Eeuo pipefail

# --- Couleurs & Variables Globales ---
APP="AdGuard Home & Unbound"
UNBOUND_PORT=5335
AGH_INSTALL_DIR="/opt/AdGuardHome"
AGH_BINARY="${AGH_INSTALL_DIR}/AdGuardHome"
AGH_YAML="${AGH_INSTALL_DIR}/AdGuardHome.yaml"
AGH_SERVICE="AdGuardHome"

# DNS Upstream Options
DNS_UPSTREAM_CLOUDFLARE="cloudflare"
DNS_UPSTREAM_QUAD9="quad9"
DNS_UPSTREAM_MULLVAD="mullvad"
SELECTED_UPSTREAM="$DNS_UPSTREAM_CLOUDFLARE"

# Flags de détection d'installation existante
AGH_ALREADY_INSTALLED=false
UNBOUND_ALREADY_INSTALLED=false
PRESERVE_NETWORK_CONFIG=false

# Codes couleur ANSI
YW=$(echo "\033[33m")
BL=$(echo "\033[34m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
WARN="${YW}⚠${CL}"

# --- Fonctions d'Affichage (Style Proxmox Helper-Scripts) ---

spinner() {
    local chars="/-\|"
    while :; do
        for (( i=0; i<${#chars}; i++ )); do
            sleep 0.1
            echo -en "${BFR}${HOLD} ${chars:$i:1}"
        done
    done
}

msg_info() {
    local msg="$1"
    echo -ne " ${HOLD} ${YW}${msg}...${CL}"
}

msg_ok() {
    local msg="$1"
    echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
    local msg="$1"
    echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

msg_warn() {
    local msg="$1"
    echo -e "${BFR} ${WARN} ${YW}${msg}${CL}"
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
                                        
EOF
    echo -e "${BL}====================================================================${CL}"
    echo -e "${GN}   AdGuard Home + Unbound :: Installation & Mise à jour${CL}"
    echo -e "${BL}====================================================================${CL}"
    echo ""
}

# --- Fonctions de Vérification ---

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
        msg_error "Impossible de détecter l'OS. /etc/os-release introuvable."
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "tar" "jq" "whiptail")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            msg_info "Installation de la dépendance manquante: $dep"
            apt-get install -y "$dep" &>/dev/null
            msg_ok "$dep installé"
        fi
    done
}

# --- Optimisation Réseau (Sysctl) ---

apply_sysctl_tuning() {
    msg_info "Application des optimisations réseau (sysctl)"
    
    local SYSCTL_CONF="/etc/sysctl.d/99-dns-optimization.conf"
    
    cat > "$SYSCTL_CONF" <<EOF
# Optimisations réseau pour DNS (généré par install script)
# Augmente les buffers UDP pour de meilleures performances DNS
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# Optimise la pile TCP/UDP
net.core.netdev_max_backlog = 50000
net.ipv4.udp_mem = 65536 131072 262144

# Désactive les réponses ICMP redirect (sécurité)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
    
    # Appliquer si on a les permissions (pas toujours possible en LXC non-privilégié)
    if sysctl -p "$SYSCTL_CONF" &>/dev/null; then
        msg_ok "Optimisations sysctl appliquées"
    else
        msg_warn "Optimisations sysctl non appliquées (LXC non-privilégié ?)"
    fi
}

# --- Sélection DNS Upstream ---

select_dns_upstream() {
    CHOICE=$(whiptail --title "Sélection DNS Upstream" --menu \
        "Choisissez votre fournisseur DNS-over-TLS upstream:" 15 70 4 \
        "1" "Cloudflare (1.1.1.1) - Rapide, global" \
        "2" "Quad9 (9.9.9.9) - Sécurisé, bloque malwares" \
        "3" "Mullvad (194.242.2.2) - Vie privée maximale" \
        "4" "Personnalisé (entrée manuelle)" \
        3>&1 1>&2 2>&3) || CHOICE="1"
    
    case $CHOICE in
        1) SELECTED_UPSTREAM="$DNS_UPSTREAM_CLOUDFLARE" ;;
        2) SELECTED_UPSTREAM="$DNS_UPSTREAM_QUAD9" ;;
        3) SELECTED_UPSTREAM="$DNS_UPSTREAM_MULLVAD" ;;
        4) 
            CUSTOM_DNS=$(whiptail --inputbox "Entrez l'adresse DNS (ex: 1.1.1.1@853#cloudflare-dns.com):" 10 70 3>&1 1>&2 2>&3)
            SELECTED_UPSTREAM="custom"
            CUSTOM_DNS_ADDR="$CUSTOM_DNS"
            ;;
        *) SELECTED_UPSTREAM="$DNS_UPSTREAM_CLOUDFLARE" ;;
    esac
}

get_upstream_config() {
    case $SELECTED_UPSTREAM in
        cloudflare)
            cat <<EOF
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
EOF
            ;;
        quad9)
            cat <<EOF
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
    forward-addr: 2620:fe::fe@853#dns.quad9.net
    forward-addr: 2620:fe::9@853#dns.quad9.net
EOF
            ;;
        mullvad)
            cat <<EOF
    forward-addr: 194.242.2.2@853#dns.mullvad.net
    forward-addr: 2a07:e340::2@853#dns.mullvad.net
EOF
            ;;
        custom)
            echo "    forward-addr: ${CUSTOM_DNS_ADDR}"
            ;;
    esac
}

# --- Préchauffage du Cache DNS ---

warmup_cache() {
    msg_info "Préchauffage du cache DNS (domaines populaires)"
    
    local domains=("google.com" "facebook.com" "youtube.com" "amazon.com" "cloudflare.com" 
                   "microsoft.com" "apple.com" "github.com" "netflix.com" "twitter.com")
    
    for domain in "${domains[@]}"; do
        dig @127.0.0.1 -p ${UNBOUND_PORT} "$domain" +short A &>/dev/null || true
    done
    
    msg_ok "Cache DNS préchauffé (${#domains[@]} domaines)"
}

# --- Fonctions de Calcul Optimisé pour Unbound ---


get_system_resources() {
    CPU_CORES=$(nproc --all)
    # RAM en Mo
    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
}

calculate_optimized_settings() {
    get_system_resources

    # Calcul du nombre de threads
    NUM_THREADS=$CPU_CORES

    # Calcul des slabs (puissance de 2 proche de num_threads)
    if [[ $CPU_CORES -le 1 ]]; then
        CACHE_SLABS=2
    elif [[ $CPU_CORES -eq 2 ]]; then
        CACHE_SLABS=2
    elif [[ $CPU_CORES -le 4 ]]; then
        CACHE_SLABS=4
    elif [[ $CPU_CORES -le 8 ]]; then
        CACHE_SLABS=8
    else
        CACHE_SLABS=16
    fi

    # Calcul des tailles de cache et paramètres basés sur la RAM
    # Adapté pour les petits LXC (512MB) jusqu'aux gros serveurs (4GB+)
    if [[ $RAM_MB -lt 512 ]]; then
        # Très petit LXC (256-511 MB)
        RRSET_CACHE_SIZE="16m"
        MSG_CACHE_SIZE="8m"
        SO_BUF="256k"
        INFRA_CACHE_HOSTS=5000
        OUTGOING_RANGE=2048
        QUERIES_PER_THREAD=1024
        NEG_CACHE_SIZE="1m"
    elif [[ $RAM_MB -lt 768 ]]; then
        # Petit LXC (512-767 MB) - comme ta config
        RRSET_CACHE_SIZE="32m"
        MSG_CACHE_SIZE="16m"
        SO_BUF="512k"
        INFRA_CACHE_HOSTS=10000
        OUTGOING_RANGE=4096
        QUERIES_PER_THREAD=2048
        NEG_CACHE_SIZE="2m"
    elif [[ $RAM_MB -lt 1024 ]]; then
        # Moyen LXC (768-1023 MB)
        RRSET_CACHE_SIZE="64m"
        MSG_CACHE_SIZE="32m"
        SO_BUF="1m"
        INFRA_CACHE_HOSTS=25000
        OUTGOING_RANGE=4096
        QUERIES_PER_THREAD=2048
        NEG_CACHE_SIZE="4m"
    elif [[ $RAM_MB -lt 2048 ]]; then
        # Grand LXC (1-2 GB)
        RRSET_CACHE_SIZE="128m"
        MSG_CACHE_SIZE="64m"
        SO_BUF="2m"
        INFRA_CACHE_HOSTS=50000
        OUTGOING_RANGE=8192
        QUERIES_PER_THREAD=4096
        NEG_CACHE_SIZE="4m"
    else
        # Très grand LXC (2GB+)
        RRSET_CACHE_SIZE="256m"
        MSG_CACHE_SIZE="128m"
        SO_BUF="4m"
        INFRA_CACHE_HOSTS=100000
        OUTGOING_RANGE=8192
        QUERIES_PER_THREAD=4096
        NEG_CACHE_SIZE="8m"
    fi

    # Afficher un résumé des ressources détectées
    msg_info "Ressources détectées: ${CPU_CORES} CPU, ${RAM_MB} MB RAM"
}


# --- Fonctions d'Installation ---

install_adguard_home() {
    if [[ -f "$AGH_BINARY" ]]; then
        msg_warn "AdGuard Home est déjà installé dans ${AGH_INSTALL_DIR}"
        AGH_ALREADY_INSTALLED=true
        return 0
    fi

    msg_info "Téléchargement de la dernière version d'AdGuard Home"
    
    # Récupérer la dernière version depuis l'API GitHub
    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.tag_name')
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        msg_error "Impossible de récupérer la dernière version d'AdGuard Home"
        exit 1
    fi
    
    # Déterminer l'architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) AGH_ARCH="amd64" ;;
        aarch64) AGH_ARCH="arm64" ;;
        armv7l) AGH_ARCH="armv7" ;;
        *) msg_error "Architecture non supportée: $ARCH"; exit 1 ;;
    esac

    AGH_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VERSION}/AdGuardHome_linux_${AGH_ARCH}.tar.gz"
    
    mkdir -p /tmp/agh_install
    cd /tmp/agh_install
    wget -q "$AGH_URL" -O AdGuardHome.tar.gz
    tar -xzf AdGuardHome.tar.gz
    
    mkdir -p "$AGH_INSTALL_DIR"
    mv AdGuardHome/AdGuardHome "$AGH_BINARY"
    chmod +x "$AGH_BINARY"
    
    rm -rf /tmp/agh_install
    msg_ok "AdGuard Home ${LATEST_VERSION} téléchargé"

    msg_info "Création du service systemd pour AdGuard Home"
    cat <<EOF >/etc/systemd/system/${AGH_SERVICE}.service
[Unit]
Description=AdGuard Home: Network-level blocker
ConditionFileIsExecutable=${AGH_BINARY}
After=syslog.target network-online.target

[Service]
StartLimitInterval=5
StartLimitBurst=10
ExecStart=${AGH_BINARY} -s run
WorkingDirectory=${AGH_INSTALL_DIR}
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable -q "${AGH_SERVICE}"
    systemctl start "${AGH_SERVICE}"
    msg_ok "Service AdGuard Home créé et démarré"

    # Attendre que le fichier YAML soit créé (premier lancement)
    msg_info "Attente de l'initialisation d'AdGuard Home (config YAML)"
    local timeout=60
    while [[ ! -f "$AGH_YAML" && $timeout -gt 0 ]]; do
        sleep 2
        ((timeout-=2))
    done
    
    if [[ -f "$AGH_YAML" ]]; then
        msg_ok "Configuration AdGuard Home initialisée"
    else
        msg_warn "Le fichier YAML n'a pas été créé automatiquement. Configuration manuelle requise."
    fi
}

install_unbound() {
    # Vérifier si Unbound est déjà installé et fonctionnel
    if systemctl is-active --quiet unbound 2>/dev/null; then
        msg_warn "Unbound est déjà installé et actif"
        UNBOUND_ALREADY_INSTALLED=true
        # Ne pas réinstaller, juste reconfigurer si nécessaire
    else
        msg_info "Installation d'Unbound"
        apt-get update &>/dev/null
        apt-get install -y unbound ca-certificates dnsutils &>/dev/null
        msg_ok "Unbound installé"
    fi

    # Arrêter Unbound pour configuration
    systemctl stop unbound &>/dev/null || true

    # Gérer systemd-resolved
    if systemctl is-active --quiet systemd-resolved; then
        if ss -tulnp | grep -E ':(53|5353)\s' | grep -q 'systemd-resolve'; then
            msg_info "Désactivation de systemd-resolved (conflit port 53)"
            systemctl disable --now systemd-resolved.service &>/dev/null
            if [[ -L /etc/resolv.conf ]]; then
                rm -f /etc/resolv.conf
            fi
            msg_ok "systemd-resolved désactivé"
        fi
    fi

    msg_info "Génération de la configuration Unbound optimisée"
    calculate_optimized_settings

    # Sauvegarde de la configuration existante
    CONF_FILE="/etc/unbound/unbound.conf"
    if [[ -f "$CONF_FILE" ]]; then
        mv "$CONF_FILE" "${CONF_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    fi

    # Création de la nouvelle configuration
    cat > "$CONF_FILE" <<EOF
# ==================================================================
# Configuration Unbound ULTRA-OPTIMISÉE pour AdGuard Home sur LXC
# Générée automatiquement le $(date)
# Ressources détectées : ${CPU_CORES} CPU / ${RAM_MB}MB RAM
# ==================================================================

server:
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow

    num-threads: ${NUM_THREADS}
    msg-cache-slabs: ${CACHE_SLABS}
    rrset-cache-slabs: ${CACHE_SLABS}
    infra-cache-slabs: ${CACHE_SLABS}
    key-cache-slabs: ${CACHE_SLABS}
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    msg-cache-size: ${MSG_CACHE_SIZE}
    so-reuseport: yes
    so-rcvbuf: ${SO_BUF}
    so-sndbuf: ${SO_BUF}

    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-ttl-reset: yes
    serve-expired-client-timeout: 1800

    # Optimisations avancées (adaptées aux ressources)
    outgoing-range: ${OUTGOING_RANGE}
    num-queries-per-thread: ${QUERIES_PER_THREAD}
    jostle-timeout: 300
    infra-host-ttl: 900
    infra-cache-numhosts: ${INFRA_CACHE_HOSTS}
    unwanted-reply-threshold: 10000000
    edns-buffer-size: 1232
    max-udp-size: 1232
    cache-min-ttl: 300
    cache-max-ttl: 86400
    cache-max-negative-ttl: 3600
    neg-cache-size: ${NEG_CACHE_SIZE}
    delay-close: 10000

    minimal-responses: yes
    qname-minimisation: yes
    qname-minimisation-strict: yes

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    deny-any: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes

    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    root-hints: "/usr/share/dns/root.hints"
    val-log-level: 1

    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    private-domain: "local"
    private-domain: "lan"
    private-domain: "home.arpa"

    extended-statistics: yes
    statistics-interval: 0
    statistics-cumulative: yes

forward-zone:
    name: "."
    forward-tls-upstream: yes
$(get_upstream_config)

remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/etc/unbound/unbound_server.key"
    server-cert-file: "/etc/unbound/unbound_server.pem"
    control-key-file: "/etc/unbound/unbound_control.key"
    control-cert-file: "/etc/unbound/unbound_control.pem"
EOF
    msg_ok "Configuration Unbound générée (${NUM_THREADS} threads, ${RRSET_CACHE_SIZE} cache)"

    # Vérification de la syntaxe
    msg_info "Vérification de la syntaxe Unbound"
    if unbound-checkconf "$CONF_FILE" &>/dev/null; then
        msg_ok "Syntaxe Unbound valide"
    else
        msg_error "Erreur de syntaxe dans la configuration Unbound"
        unbound-checkconf "$CONF_FILE"
        exit 1
    fi

    # Configuration de unbound-control
    if [[ ! -f "/etc/unbound/unbound_server.key" ]]; then
        msg_info "Génération des clés unbound-control"
        unbound-control-setup &>/dev/null || true
        msg_ok "Clés unbound-control générées"
    fi

    # Permissions
    chown -R unbound:unbound /etc/unbound/ /var/lib/unbound/ 2>/dev/null || true

    # Démarrage d'Unbound
    msg_info "Démarrage du service Unbound"
    systemctl daemon-reload
    systemctl enable -q unbound
    systemctl restart unbound
    sleep 2

    if systemctl is-active --quiet unbound; then
        msg_ok "Service Unbound démarré"
        # Test DNS
        if dig @127.0.0.1 -p ${UNBOUND_PORT} google.com +short A +tries=1 +time=2 &>/dev/null; then
            msg_ok "Test DNS via Unbound réussi"
        else
            msg_warn "Unbound démarré mais le test DNS a échoué"
        fi
    else
        msg_error "Échec du démarrage d'Unbound"
        journalctl -u unbound --no-pager -n 20
        exit 1
    fi
}

configure_adguard_upstream() {
    if [[ ! -f "$AGH_YAML" ]]; then
        msg_warn "Fichier AdGuardHome.yaml introuvable. Configuration manuelle requise."
        return 1
    fi

    # Ne pas modifier la configuration AGH si déjà installé
    # L'utilisateur a probablement déjà configuré ses upstreams
    if [[ "$AGH_ALREADY_INSTALLED" == true ]]; then
        msg_warn "AdGuard Home était déjà installé - configuration DNS amont préservée"
        msg_info "Vérifiez manuellement que 127.0.0.1:${UNBOUND_PORT} est configuré comme upstream"
        return 0
    fi

    msg_info "Configuration d'Unbound comme serveur DNS amont dans AdGuard Home"
    
    # Arrêter AGH pour modifier le YAML
    systemctl stop "${AGH_SERVICE}" &>/dev/null || true
    
    # Sauvegarde
    cp "$AGH_YAML" "${AGH_YAML}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Modifier le fichier YAML pour utiliser Unbound
    # On remplace les upstreams existants par Unbound local
    if command -v python3 &>/dev/null; then
        python3 <<PYTHON
import yaml
import sys

try:
    with open("$AGH_YAML", 'r') as f:
        config = yaml.safe_load(f)
    
    if 'dns' not in config:
        config['dns'] = {}
    
    config['dns']['upstream_dns'] = ['127.0.0.1:${UNBOUND_PORT}']
    config['dns']['bootstrap_dns'] = ['1.1.1.1', '9.9.9.9']
    
    with open("$AGH_YAML", 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTHON
    else
        # Fallback: utiliser sed si Python n'est pas disponible
        # Cette méthode est moins fiable mais fonctionne pour les cas simples
        sed -i 's/upstream_dns:.*/upstream_dns:\n  - 127.0.0.1:'"${UNBOUND_PORT}"'/' "$AGH_YAML" 2>/dev/null || true
    fi
    
    # Redémarrer AGH
    systemctl start "${AGH_SERVICE}"
    msg_ok "AdGuard Home configuré pour utiliser Unbound (127.0.0.1:${UNBOUND_PORT})"
}

configure_resolv_conf() {
    # Ne pas modifier resolv.conf si les deux services étaient déjà installés
    # Cela évite de casser la configuration réseau existante (routeur, etc.)
    if [[ "$AGH_ALREADY_INSTALLED" == true && "$UNBOUND_ALREADY_INSTALLED" == true ]]; then
        msg_warn "Configuration réseau préservée (installation existante détectée)"
        msg_info "Le fichier /etc/resolv.conf n'a pas été modifié"
        return 0
    fi
    
    msg_info "Configuration de /etc/resolv.conf"
    cat > /etc/resolv.conf <<EOF
# Configuré par le script All-in-One AdGuard/Unbound
nameserver 127.0.0.1
options edns0 trust-ad
EOF
    # Empêcher l'écrasement par Proxmox/DHCP
    touch /etc/.pve-ignore.resolv.conf 2>/dev/null || true
    msg_ok "/etc/resolv.conf configuré"
}

# --- Fonctions de Mise à jour ---

update_unbound() {
    msg_info "Mise à jour d'Unbound"
    apt-get update &>/dev/null
    apt-get install --only-upgrade -y unbound &>/dev/null
    msg_ok "Unbound mis à jour"

    # Mise à jour des root hints
    msg_info "Mise à jour des Root Hints DNS"
    wget -q -O /usr/share/dns/root.hints https://www.internic.net/domain/named.cache 2>/dev/null || true
    msg_ok "Root Hints mis à jour"

    systemctl restart unbound
    msg_ok "Service Unbound redémarré"
}

update_adguard_home() {
    if [[ ! -f "$AGH_BINARY" ]]; then
        msg_error "AdGuard Home n'est pas installé. Utilisez l'option Installation."
        return 1
    fi

    msg_info "Vérification de la version d'AdGuard Home"
    
    CURRENT_VERSION=$("$AGH_BINARY" --version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1) || CURRENT_VERSION="unknown"
    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.tag_name')

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        msg_ok "AdGuard Home est déjà à jour (${CURRENT_VERSION})"
        return 0
    fi

    msg_info "Mise à jour d'AdGuard Home: ${CURRENT_VERSION} → ${LATEST_VERSION}"
    
    # Déterminer l'architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) AGH_ARCH="amd64" ;;
        aarch64) AGH_ARCH="arm64" ;;
        armv7l) AGH_ARCH="armv7" ;;
        *) msg_error "Architecture non supportée: $ARCH"; return 1 ;;
    esac

    AGH_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VERSION}/AdGuardHome_linux_${AGH_ARCH}.tar.gz"
    
    # Arrêter le service
    systemctl stop "${AGH_SERVICE}"
    
    # Backup du binaire actuel
    cp "$AGH_BINARY" "${AGH_BINARY}.backup"
    
    # Télécharger et installer
    mkdir -p /tmp/agh_update
    cd /tmp/agh_update
    wget -q "$AGH_URL" -O AdGuardHome.tar.gz
    tar -xzf AdGuardHome.tar.gz
    mv AdGuardHome/AdGuardHome "$AGH_BINARY"
    chmod +x "$AGH_BINARY"
    rm -rf /tmp/agh_update
    
    # Redémarrer le service
    systemctl start "${AGH_SERVICE}"
    
    msg_ok "AdGuard Home mis à jour vers ${LATEST_VERSION}"
}

update_all() {
    header_info
    echo -e "${INFO} Mise à jour complète du système DNS...\n"
    
    update_unbound
    update_adguard_home
    
    echo ""
    msg_ok "Mise à jour terminée avec succès!"
}

# --- Fonction d'Installation Complète ---

full_install() {
    header_info
    echo -e "${INFO} Installation complète AdGuard Home + Unbound...\n"
    
    # Sélection du fournisseur DNS upstream
    select_dns_upstream
    
    msg_info "Mise à jour du système"
    apt-get update &>/dev/null
    apt-get upgrade -y &>/dev/null
    msg_ok "Système mis à jour"
    
    # Optimisations système
    apply_sysctl_tuning
    
    install_adguard_home
    install_unbound
    configure_adguard_upstream
    configure_resolv_conf
    
    # Préchauffage du cache
    warmup_cache
    
    echo ""
    echo -e "${GN}╔════════════════════════════════════════════════════════════════╗${CL}"
    echo -e "${GN}║              Installation Terminée avec Succès !               ║${CL}"
    echo -e "${GN}╚════════════════════════════════════════════════════════════════╝${CL}"
    echo ""
    echo -e "${INFO} AdGuard Home Web UI: ${GN}http://$(hostname -I | awk '{print $1}'):3000${CL}"
    echo -e "${INFO} Unbound écoute sur: ${GN}127.0.0.1:${UNBOUND_PORT}${CL}"
    echo -e "${INFO} DNS Upstream: ${GN}${SELECTED_UPSTREAM}${CL}"
    echo ""
    echo -e "${YW}Paramètres Unbound optimisés:${CL}"
    echo -e "  - Threads: ${GN}${NUM_THREADS}${CL}"
    echo -e "  - Slabs: ${GN}${CACHE_SLABS}${CL}"
    echo -e "  - Cache RRset: ${GN}${RRSET_CACHE_SIZE}${CL}"
    echo -e "  - Cache Message: ${GN}${MSG_CACHE_SIZE}${CL}"
    echo ""
}


# --- Menu Principal ---

show_menu() {
    header_info
    
    CHOICE=$(whiptail --title "AdGuard Home & Unbound Manager" --menu \
        "Choisissez une option:" 18 70 5 \
        "1" "Installation Complète (AdGuard Home + Unbound)" \
        "2" "Mise à jour Complète" \
        "3" "Installer uniquement Unbound" \
        "4" "Afficher les Statistiques" \
        "5" "Quitter" \
        3>&1 1>&2 2>&3)
    
    case $CHOICE in
        1)
            full_install
            ;;
        2)
            update_all
            ;;
        3)
            install_unbound
            ;;
        4)
            header_info
            echo -e "${INFO} Statistiques Unbound:\n"
            unbound-control stats_noreset 2>/dev/null || msg_warn "unbound-control non disponible"
            ;;
        5)
            echo -e "${INFO} Au revoir!"
            exit 0
            ;;
        *)
            echo -e "${INFO} Opération annulée."
            exit 0
            ;;
    esac
}

# --- Point d'Entrée ---

main() {
    check_root
    check_os
    check_dependencies
    
    case "${1:-}" in
        --install)
            full_install
            ;;
        --update)
            update_all
            ;;
        --unbound-only)
            install_unbound
            ;;
        --help|-h)
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  --install        Installation complète (AdGuard Home + Unbound)"
            echo "  --update         Mise à jour complète"
            echo "  --unbound-only   Installer uniquement Unbound"
            echo "  --help           Afficher cette aide"
            echo ""
            echo "Sans option, le script affiche un menu interactif."
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
