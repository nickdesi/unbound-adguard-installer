#!/usr/bin/env bash

# ==========================================================================
# AdGuard Home & Unbound All-in-One Installer/Updater pour Proxmox LXC
# ==========================================================================
# Script inspiré du style "Proxmox VE Helper-Scripts" (tteck/community-scripts)
# Installe, configure et met à jour AdGuard Home + Unbound sur Debian/Ubuntu LXC.
# ==========================================================================
# Auteur: Nicolas
# Version: 3.4.1
# Licence: MIT
# ==========================================================================

# --- Safety & Error Handling ---
set -Eeuo pipefail
trap cleanup EXIT
trap 'error_handler $? $LINENO $BASH_COMMAND' ERR

# --- Load Shared Libraries (fail-fast) ---
# common.sh est OBLIGATOIRE — le script ne peut pas fonctionner sans.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    echo "FATAL: lib/common.sh introuvable dans ${SCRIPT_DIR}/lib/" >&2
    echo "Assurez-vous de cloner le repo complet et non de télécharger le script seul." >&2
    exit 1
fi
source "${SCRIPT_DIR}/lib/common.sh"

# health_checks.sh est optionnel (dégradation gracieuse)
HEALTH_CHECKS_AVAILABLE=false
if [[ -f "${SCRIPT_DIR}/lib/health_checks.sh" ]]; then
    source "${SCRIPT_DIR}/lib/health_checks.sh"
    HEALTH_CHECKS_AVAILABLE=true
fi

# --- Global Constants ---
readonly SCRIPT_VERSION="3.4.1"
readonly UNBOUND_PORT=5335
readonly AGH_INSTALL_DIR="/opt/AdGuardHome"
readonly AGH_BINARY="${AGH_INSTALL_DIR}/AdGuardHome"
readonly AGH_YAML="${AGH_INSTALL_DIR}/AdGuardHome.yaml"
readonly VALID_UPSTREAMS=("cloudflare" "quad9" "google" "adguard")
readonly ROOT_HINTS_FILE="/usr/share/dns/root.hints"
readonly ROOT_HINTS_MAX_AGE_DAYS=30
readonly UNBOUND_CONF="/etc/unbound/unbound.conf"
readonly UNBOUND_CONF_NEW="/etc/unbound/unbound.conf.d/99-adguard-unbound-installer.conf"
readonly UNBOUND_TRUST_ANCHOR="/var/lib/unbound/root.key"
readonly DEFAULT_BENCHMARK_QUERIES=300

# Global State Variables (mutable)
INTERACTIVE=true
SELECTED_UPSTREAM="cloudflare"
DRY_RUN=false
CPU_CORES=1
RAM_MB=512
ALLOW_PROXMOX_HOST=false

# --- Error Handling & Cleanup ---

cleanup() {
    rm -rf /tmp/agh_install /tmp/agh_update 2>/dev/null || true
}

error_handler() {
    local exit_code="$1" line_number="$2" command="$3"
    msg_error "Erreur ligne ${line_number}: '${command}' a échoué (code ${exit_code})"
}

# --- Dry-run wrapper ---
# Usage: run_cmd <cmd> [args...]
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
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
    echo -e "                                        v${SCRIPT_VERSION}"
    echo -e "${BL}====================================================================${CL}"
    echo -e "${GN}   AdGuard Home + Unbound :: Installation & Tuning${CL}"
    echo -e "${BL}====================================================================${CL}"
    echo ""
}

# --- System Checks ---

sanitize_textbox_output() {
    tr '\r' '\n' \
        | sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g; s/✓/[OK]/g; s/✗/[ERR]/g; s/⚠/[WARN]/g; s/ℹ/[INFO]/g' \
        | awk '
            function wrap(line, width, pos) {
                gsub(/[[:space:]]+$/, "", line)
                while (length(line) > width) {
                    pos = width
                    while (pos > 1 && substr(line, pos, 1) != " ") pos--
                    if (pos <= 1) pos = width
                    print substr(line, 1, pos)
                    line = substr(line, pos + 1)
                    sub(/^[[:space:]]+/, "", line)
                }
                print line
            }
            { wrap($0, 76) }
        '
}

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
            msg_error "OS non supporté: $ID (Debian/Ubuntu requis)"
            exit 1
        fi
    else
        msg_error "Impossible de détecter l'OS."
        exit 1
    fi
}

is_proxmox_host() {
    [[ -d /etc/pve ]] || command -v pveversion &>/dev/null
}

is_lxc_container() {
    grep -qaE 'lxc|liblxc' /proc/1/environ /proc/1/cgroup 2>/dev/null \
        || systemd-detect-virt --container 2>/dev/null | grep -q '^lxc$' \
        || [[ -f /run/systemd/container && "$(cat /run/systemd/container 2>/dev/null)" == "lxc" ]]
}

check_proxmox_target() {
    if is_proxmox_host && [[ "$ALLOW_PROXMOX_HOST" != "true" ]]; then
        msg_error "Hôte Proxmox détecté. Installez ce service dans un conteneur LXC Debian/Ubuntu, pas sur le nœud PVE."
        msg_error "Contournement non recommandé: --allow-proxmox-host"
        exit 1
    fi

    if is_lxc_container; then
        msg_ok "Environnement LXC détecté"
    else
        msg_warn "Aucun conteneur LXC détecté — script optimisé pour Proxmox LXC Debian/Ubuntu."
    fi
}

check_dependencies() {
    local missing_cmds=() missing_pkgs=()
    local dep cmd pkg
    local deps=(
        "curl:curl" "wget:wget" "tar:tar" "jq:jq" "whiptail:whiptail"
        "openssl:openssl" "ss:iproute2" "awk:mawk" "sed:sed" "grep:grep"
    )

    for dep in "${deps[@]}"; do
        cmd="${dep%%:*}"
        pkg="${dep#*:}"
        command -v "$cmd" &>/dev/null || { missing_cmds+=("$cmd"); missing_pkgs+=("$pkg"); }
    done
    command -v dig &>/dev/null || { missing_cmds+=("dig"); missing_pkgs+=("bind9-dnsutils"); }
    if ! command -v python3 &>/dev/null; then
        missing_cmds+=("python3" "python3-yaml")
        missing_pkgs+=("python3" "python3-yaml")
    elif ! python3 -c "import yaml" &>/dev/null 2>&1; then
        missing_cmds+=("python3-yaml")
        missing_pkgs+=("python3-yaml")
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        msg_info "Installation des dépendances manquantes: ${missing_cmds[*]}"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY-RUN] apt-get install -y --no-install-recommends ${missing_pkgs[*]}"
            msg_ok "Dépendances simulées"
            return 0
        fi
        local cache_age
        cache_age=$(stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0)
        (( $(date +%s) - cache_age > 3600 )) && apt-get update -qq &>/dev/null
        apt-get install -y --no-install-recommends "${missing_pkgs[@]}" &>/dev/null
        msg_ok "Dépendances installées"
    fi
}

refresh_root_hints_if_needed() {
    local max_age_seconds=$((ROOT_HINTS_MAX_AGE_DAYS * 86400))
    local file_age=999999999

    [[ "$DRY_RUN" == "true" ]] && { echo "  [DRY-RUN] Vérification root hints"; return 0; }
    mkdir -p "$(dirname "$ROOT_HINTS_FILE")"

    if [[ -f "$ROOT_HINTS_FILE" ]]; then
        file_age=$(( $(date +%s) - $(stat -c %Y "$ROOT_HINTS_FILE" 2>/dev/null || echo 0) ))
    fi

    if (( file_age > max_age_seconds )); then
        msg_info "Mise à jour root hints (cache ${ROOT_HINTS_MAX_AGE_DAYS}j)"
        download_with_retry "https://www.internic.net/domain/named.cache" "$ROOT_HINTS_FILE" 3 >/dev/null && msg_ok "Root hints à jour" || msg_warn "Root hints non mis à jour"
    fi
}

repair_unbound_trust_anchor() {
    [[ "$DRY_RUN" == "true" ]] && { echo "  [DRY-RUN] Réparation trust anchor DNSSEC"; return 0; }

    msg_warn "Réparation de la trust anchor DNSSEC Unbound"

    local conf_file external_anchor=false
    for conf_file in /etc/unbound/unbound.conf /etc/unbound/unbound.conf.d/*.conf; do
        [[ -f "$conf_file" && "$conf_file" != "$UNBOUND_CONF_NEW" ]] || continue
        if grep -qE '^[[:space:]]*auto-trust-anchor-file:[[:space:]]' "$conf_file"; then
            external_anchor=true
            break
        fi
    done

    if [[ "$external_anchor" == "true" ]] && grep -qE '^[[:space:]]*auto-trust-anchor-file:[[:space:]]' "$UNBOUND_CONF_NEW" 2>/dev/null; then
        cp -a "$UNBOUND_CONF_NEW" "${UNBOUND_CONF_NEW}.backup.$(date +%s)" 2>/dev/null || true
        sed -i -E 's/^([[:space:]]*auto-trust-anchor-file:[[:space:]].*)/# disabled by unbound-adguard-installer: \1/' "$UNBOUND_CONF_NEW" 2>/dev/null || true
        msg_warn "Directive DNSSEC dupliquée désactivée dans la configuration du script"
    fi

    mkdir -p "$(dirname "$UNBOUND_TRUST_ANCHOR")"
    [[ -f "$UNBOUND_TRUST_ANCHOR" ]] && cp -a "$UNBOUND_TRUST_ANCHOR" "${UNBOUND_TRUST_ANCHOR}.backup.$(date +%s)" || true
    rm -f "$UNBOUND_TRUST_ANCHOR"

    if command -v unbound-anchor &>/dev/null && unbound-anchor -a "$UNBOUND_TRUST_ANCHOR" &>/dev/null; then
        chown unbound:unbound "$UNBOUND_TRUST_ANCHOR" 2>/dev/null || true
        chmod 644 "$UNBOUND_TRUST_ANCHOR" 2>/dev/null || true
        msg_ok "Trust anchor DNSSEC régénérée"
        systemctl restart unbound &>/dev/null || true
        return 0
    fi

    if [[ -s /usr/share/dns/root.key ]]; then
        cp /usr/share/dns/root.key "$UNBOUND_TRUST_ANCHOR"
        chown unbound:unbound "$UNBOUND_TRUST_ANCHOR" 2>/dev/null || true
        chmod 644 "$UNBOUND_TRUST_ANCHOR" 2>/dev/null || true
        msg_ok "Trust anchor DNSSEC restaurée depuis /usr/share/dns/root.key"
        systemctl restart unbound &>/dev/null || true
        return 0
    fi

    msg_warn "Trust anchor DNSSEC non régénérée automatiquement"
    return 1
}

# --- Upstream Validation ---

validate_upstream() {
    local up="$1"
    local valid
    for valid in "${VALID_UPSTREAMS[@]}"; do
        [[ "$up" == "$valid" ]] && return 0
    done
    msg_error "Upstream invalide: '$up'. Valeurs acceptées: ${VALID_UPSTREAMS[*]}"
    return 1
}

# --- Network Optimization (Sysctl) ---

apply_sysctl_tuning() {
    msg_info "Application des optimisations réseau (sysctl)"
    local SYSCTL_CONF="/etc/sysctl.d/99-dns-optimization.conf"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Écriture de $SYSCTL_CONF"
        return 0
    fi
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
    if sysctl -p "$SYSCTL_CONF" &>/dev/null; then
        msg_ok "Optimisations sysctl appliquées"
    else
        msg_warn "Optimisations sysctl non appliquées (LXC non-privilégié ?)"
    fi
}

# --- Unbound Logic & Calculation ---

get_power_of_two() {
    local n=$1 p=1
    while (( p * 2 <= n )); do (( p *= 2 )); done
    echo "$p"
}

get_system_resources() {
    CPU_CORES=$(nproc --all)
    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
}

calculate_optimized_settings() {
    get_system_resources

    if [[ "$INTERACTIVE" == "true" ]]; then
        if ! whiptail --title "Ressources systeme" --yesno \
            "Détecté : ${CPU_CORES} CPU, ${RAM_MB} MB RAM.\n\nUtiliser ces valeurs pour l'auto-configuration ?" 10 60; then
            local user_cpu user_ram
            if user_cpu=$(whiptail --inputbox "Nombre de coeurs CPU :" 8 40 "$CPU_CORES" 3>&1 1>&2 2>&3); then
                if [[ "$user_cpu" =~ ^[0-9]+$ ]] && (( user_cpu > 0 && user_cpu <= 256 )); then
                    CPU_CORES=$user_cpu
                else
                    msg_warn "Valeur CPU invalide. Valeur détectée conservée ($CPU_CORES)."
                fi
            fi
            if user_ram=$(whiptail --inputbox "RAM en MB :" 8 40 "$RAM_MB" 3>&1 1>&2 2>&3); then
                if [[ "$user_ram" =~ ^[0-9]+$ ]] && (( user_ram >= 64 && user_ram <= 1048576 )); then
                    RAM_MB=$user_ram
                else
                    msg_warn "Valeur RAM invalide. Valeur détectée conservée ($RAM_MB)."
                fi
            fi
        fi
    fi

    NUM_THREADS=$CPU_CORES
    if (( CPU_CORES == 1 )); then
        CACHE_SLABS=1
        NUM_THREADS=1
    else
        CACHE_SLABS=$(get_power_of_two "$CPU_CORES")
        (( CACHE_SLABS < 2 )) && CACHE_SLABS=2
    fi

    if (( RAM_MB < 512 )); then
        RRSET_CACHE_SIZE="16m";  MSG_CACHE_SIZE="8m";   SO_RCVBUF="1m"; SO_SNDBUF="1m"
        INFRA_HOSTS=200;         OUTGOING_RANGE=512;    QUERIES_PER_THREAD=512; NEG_CACHE_SIZE="1m"
    elif (( RAM_MB < 1024 )); then
        RRSET_CACHE_SIZE="64m";  MSG_CACHE_SIZE="32m";  SO_RCVBUF="2m"; SO_SNDBUF="2m"
        INFRA_HOSTS=10000;       OUTGOING_RANGE=2048;   QUERIES_PER_THREAD=1024; NEG_CACHE_SIZE="4m"
    elif (( RAM_MB < 4096 )); then
        RRSET_CACHE_SIZE="256m"; MSG_CACHE_SIZE="128m"; SO_RCVBUF="4m"; SO_SNDBUF="4m"
        INFRA_HOSTS=50000;       OUTGOING_RANGE=8192;   QUERIES_PER_THREAD=4096; NEG_CACHE_SIZE="32m"
    else
        RRSET_CACHE_SIZE="512m"; MSG_CACHE_SIZE="256m"; SO_RCVBUF="8m"; SO_SNDBUF="8m"
        INFRA_HOSTS=100000;      OUTGOING_RANGE=8192;   QUERIES_PER_THREAD=8192; NEG_CACHE_SIZE="64m"
    fi

    CACHE_MIN_TTL=60
    CACHE_MAX_TTL=86400
    SERVE_EXPIRED_TTL=86400
    SERVE_EXPIRED_CLIENT_TIMEOUT=1800
}

install_unbound() {
    if ! dpkg -l unbound 2>/dev/null | grep -q "^ii "; then
        msg_info "Installation du paquet Unbound"
        run_cmd apt-get install -y --no-install-recommends unbound ca-certificates dnsutils &>/dev/null
        msg_ok "Unbound installé"
    else
        msg_ok "Paquet Unbound déjà présent"
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if ss -tulnp | grep -E ':(53|5353)\s' | grep -q 'systemd-resolve'; then
            msg_info "Désactivation de systemd-resolved (conflit port 53)"
            run_cmd systemctl disable --now systemd-resolved.service &>/dev/null || true
            run_cmd rm -f /etc/resolv.conf
            msg_ok "systemd-resolved désactivé"
        fi
    fi

    calculate_optimized_settings

    if [[ -f "/etc/unbound/unbound.conf" ]]; then
        run_cmd mv "/etc/unbound/unbound.conf" "/etc/unbound/unbound.conf.backup.$(date +%s)"
    fi

    local anchor_directive="    auto-trust-anchor-file: \"${UNBOUND_TRUST_ANCHOR}\""
    local conf_file
    for conf_file in /etc/unbound/unbound.conf.d/*.conf; do
        [[ -f "$conf_file" && "$conf_file" != "$UNBOUND_CONF_NEW" ]] || continue
        if grep -qE '^[[:space:]]*auto-trust-anchor-file:[[:space:]]' "$conf_file"; then
            anchor_directive="    # auto-trust-anchor-file fourni par la configuration Unbound existante"
            break
        fi
    done

    msg_info "Génération de la configuration Unbound (Threads: $NUM_THREADS, Slabs: $CACHE_SLABS)"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p /etc/unbound/unbound.conf.d /var/lib/unbound
        cat > "${UNBOUND_CONF}.tmp" <<'EOF'
include: "/etc/unbound/unbound.conf.d/*.conf"
EOF
        mv "${UNBOUND_CONF}.tmp" "$UNBOUND_CONF"
        cat > "${UNBOUND_CONF_NEW}.tmp" <<EOF
server:
    verbosity: 1
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    chroot: ""
    username: "unbound"
    directory: "/etc/unbound"
    logfile: ""
    use-syslog: yes
    root-hints: "${ROOT_HINTS_FILE}"
${anchor_directive}

    # --- Performance Tuning ---
    num-threads: ${NUM_THREADS}
    msg-cache-slabs: ${CACHE_SLABS}
    rrset-cache-slabs: ${CACHE_SLABS}
    infra-cache-slabs: ${CACHE_SLABS}
    key-cache-slabs: ${CACHE_SLABS}
    rrset-cache-size: ${RRSET_CACHE_SIZE}
    msg-cache-size: ${MSG_CACHE_SIZE}
    neg-cache-size: ${NEG_CACHE_SIZE}

    # --- Réseau ---
    so-reuseport: yes
    so-rcvbuf: ${SO_RCVBUF}
    so-sndbuf: ${SO_SNDBUF}
    edns-buffer-size: 1232
    max-udp-size: 1232
    outgoing-range: ${OUTGOING_RANGE}
    num-queries-per-thread: ${QUERIES_PER_THREAD}
    infra-cache-numhosts: ${INFRA_HOSTS}
    minimal-responses: yes
    rrset-roundrobin: yes

    # --- Cache & latence ---
    cache-min-ttl: ${CACHE_MIN_TTL}
    cache-max-ttl: ${CACHE_MAX_TTL}
    serve-expired: yes
    serve-expired-ttl: ${SERVE_EXPIRED_TTL}
    serve-expired-client-timeout: ${SERVE_EXPIRED_CLIENT_TIMEOUT}
    serve-expired-reply-ttl: 30
    prefetch: yes
    prefetch-key: yes
    aggressive-nsec: yes

    # --- Sécurité & Vie privée ---
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-algo-downgrade: yes
    qname-minimisation: yes
    use-caps-for-id: yes
    private-address: 192.168.0.0/16
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12

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
        mv "${UNBOUND_CONF_NEW}.tmp" "$UNBOUND_CONF_NEW"
    fi

    refresh_root_hints_if_needed &
    local _root_hints_pid=$!

    if [[ ! -f "/etc/unbound/unbound_server.key" ]] && [[ "$DRY_RUN" != "true" ]]; then
        msg_info "Génération des clés de contrôle Unbound"
        unbound-control-setup &>/dev/null || true
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        [[ -s "$UNBOUND_TRUST_ANCHOR" ]] || repair_unbound_trust_anchor || true
        chown -R unbound:unbound /etc/unbound /var/lib/unbound
        chmod 755 /etc/unbound /etc/unbound/unbound.conf.d /var/lib/unbound
        chmod 640 /etc/unbound/unbound_control.* 2>/dev/null || true
        chmod 644 "$ROOT_HINTS_FILE" 2>/dev/null || true
    fi

    wait "${_root_hints_pid:-}" 2>/dev/null || true

    if [[ "$DRY_RUN" == "true" ]]; then
        msg_ok "[DRY-RUN] Configuration Unbound simulée"
        return 0
    fi

    local checkconf_output=""
    local checkconf_ok=false
    if checkconf_output=$(unbound-checkconf 2>&1); then
        checkconf_ok=true
    elif grep -qiE 'trust anchor|auto-trust-anchor|root\.key' <<< "$checkconf_output"; then
        repair_unbound_trust_anchor || true
        if checkconf_output=$(unbound-checkconf 2>&1); then
            checkconf_ok=true
        fi
    fi

    if [[ "$checkconf_ok" == "true" ]]; then
        systemctl enable unbound &>/dev/null
        restart_service_safely unbound 30 || { msg_error "Échec redémarrage sécurisé Unbound"; exit 1; }
        msg_ok "Configuration Unbound valide et service redémarré"
    else
        msg_error "Configuration Unbound invalide !"
        printf '%s\n' "$checkconf_output"
        exit 1
    fi
}

get_upstream_forward_lines() {
    case "$SELECTED_UPSTREAM" in
        cloudflare)
            echo "forward-addr: 1.1.1.1@853#cloudflare-dns.com"
            echo "    forward-addr: 1.0.0.1@853#cloudflare-dns.com"
            ;;
        quad9)
            echo "forward-addr: 9.9.9.9@853#dns.quad9.net"
            echo "    forward-addr: 149.112.112.112@853#dns.quad9.net"
            ;;
        google)
            echo "forward-addr: 8.8.8.8@853#dns.google"
            echo "    forward-addr: 8.8.4.4@853#dns.google"
            ;;
        adguard)
            echo "forward-addr: 94.140.14.14@853#dns.adguard.com"
            echo "    forward-addr: 94.140.15.15@853#dns.adguard.com"
            ;;
        *)
            msg_warn "Upstream '$SELECTED_UPSTREAM' non reconnu, fallback Cloudflare"
            echo "forward-addr: 1.1.1.1@853#cloudflare-dns.com"
            echo "    forward-addr: 1.0.0.1@853#cloudflare-dns.com"
            ;;
    esac
}

# --- AdGuard Home Logic ---

configure_adguard_upstream() {
    [[ ! -f "$AGH_YAML" ]] && return 0

    msg_info "Vérification de la configuration AdGuard Home..."

    if grep -q "127.0.0.1:${UNBOUND_PORT}" "$AGH_YAML"; then
        msg_ok "AdGuard Home utilise déjà Unbound (idempotent)"
        return 0
    fi

    msg_info "Configuration d'AdGuard Home pour utiliser Unbound"

    create_backup "$AGH_YAML" || true

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Mise à jour upstream dans $AGH_YAML"
        return 0
    fi

    if command -v python3 &>/dev/null; then
        python3 - <<PYTHON
import yaml, sys
try:
    with open("$AGH_YAML", 'r') as f:
        config = yaml.safe_load(f) or {}
    config.setdefault('dns', {})
    config['dns']['upstream_dns']  = ['127.0.0.1:${UNBOUND_PORT}']
    config['dns']['bootstrap_dns'] = ['1.1.1.1', '9.9.9.9']
    config['dns']['enable_dnssec'] = True
    config['dns']['cache_size'] = max(int(config['dns'].get('cache_size') or 0), 4194304)
    config['dns']['cache_ttl_min'] = max(int(config['dns'].get('cache_ttl_min') or 0), 60)
    config['dns']['cache_ttl_max'] = max(int(config['dns'].get('cache_ttl_max') or 0), 86400)
    config['dns']['optimistic_cache'] = True
    with open("$AGH_YAML", 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print('OK')
except Exception as e:
    print(f'ERREUR: {e}', file=sys.stderr)
    sys.exit(1)
PYTHON
    else
        safe_sed "$AGH_YAML" "^  - https://dns10.quad9.net/dns-query" "  - 127.0.0.1:${UNBOUND_PORT}" || true
    fi

    restart_service_safely AdGuardHome 30 || true
    msg_ok "AdGuard Home reconfiguré pour utiliser Unbound"
}

install_adguard_home() {
    if [[ -f "$AGH_BINARY" ]]; then
        msg_ok "AdGuard Home déjà installé (idempotent)"
        configure_adguard_upstream
        return 0
    fi

    check_disk_space /opt 150 || { msg_error "Espace disque insuffisant (150 MB requis)"; return 1; }

    msg_info "Détection architecture..."
    local ARCH AGH_ARCH
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  AGH_ARCH="amd64"  ;;
        aarch64) AGH_ARCH="arm64"  ;;
        armv7l)  AGH_ARCH="armv7"  ;;
        *) msg_error "Architecture non supportée: $ARCH"; exit 1 ;;
    esac

    msg_info "Récupération de la dernière version AdGuard Home..."
    local LATEST_VER
    LATEST_VER=$(fetch_json_api "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.tag_name')

    if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
        msg_error "Impossible de trouver la dernière version AdGuard Home"
        exit 1
    fi

    local url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VER}/AdGuardHome_linux_${AGH_ARCH}.tar.gz"

    if [[ "$DRY_RUN" == "true" ]]; then
        msg_ok "[DRY-RUN] Téléchargement simulé: $url"
        return 0
    fi

    mkdir -p /tmp/agh_install
    download_with_retry "$url" "/tmp/agh_install/AGH.tar.gz" 3 || {
        msg_error "Échec téléchargement AdGuard Home"; return 1
    }

    tar -xzf /tmp/agh_install/AGH.tar.gz -C /tmp/agh_install
    mkdir -p "$AGH_INSTALL_DIR"
    mv /tmp/agh_install/AdGuardHome/AdGuardHome "$AGH_BINARY"
    chmod +x "$AGH_BINARY"

    "$AGH_BINARY" -s install &>/dev/null || true
    systemctl start AdGuardHome

    msg_info "Attente initialisation AdGuard Home..."
    if wait_for_file "$AGH_YAML" 30; then
        configure_adguard_upstream
        msg_ok "AdGuard Home v${LATEST_VER} installé et lié à Unbound"
        if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]]; then
            msg_info "Health check post-installation..."
            check_adguard_health &>/dev/null && msg_ok "Health check: OK" || msg_warn "Health check: voir logs"
        fi
    else
        msg_warn "Fichier YAML non trouvé, configuration manuelle requise"
    fi
}

# --- Uninstall Logic ---

uninstall_all() {
    if ! whiptail --title "Desinstallation" --yesno \
        "Voulez-vous vraiment désinstaller AdGuard Home et Unbound ?\nLes fichiers de configuration seront supprimés." 10 60; then
        return 0
    fi

    msg_info "Suppression AdGuard Home..."
    systemctl stop AdGuardHome &>/dev/null || true
    [[ -x "$AGH_BINARY" ]] && "$AGH_BINARY" -s uninstall &>/dev/null || true
    rm -rf "$AGH_INSTALL_DIR"
    msg_ok "AdGuard Home supprimé"

    msg_info "Suppression Unbound..."
    systemctl stop unbound &>/dev/null || true
    apt-get remove --purge -y unbound &>/dev/null
    rm -rf /etc/unbound
    msg_ok "Unbound supprimé"

    msg_ok "Désinstallation terminée"
}

# --- Main Menus ---

select_upstream() {
    local cf_tag q9_tag gg_tag ag_tag
    cf_tag="OFF"; q9_tag="OFF"; gg_tag="OFF"; ag_tag="OFF"
    case "$SELECTED_UPSTREAM" in
        cloudflare) cf_tag="ON" ;;
        quad9)      q9_tag="ON" ;;
        google)     gg_tag="ON" ;;
        adguard)    ag_tag="ON" ;;
    esac

    local choice
    choice=$(whiptail \
        --title " DNS-over-TLS Upstream (port 853) " \
        --ok-button "Confirmer" \
        --cancel-button "Annuler" \
        --radiolist "Choisissez le fournisseur upstream :\n(Espace pour selectionner, Entree pour confirmer)" 16 72 4 \
        "cloudflare" "Cloudflare    1.1.1.1   - Rapide, sans log"              "$cf_tag" \
        "quad9"      "Quad9         9.9.9.9   - DNSSEC strict, filtrage menaces" "$q9_tag" \
        "google"     "Google        8.8.8.8   - Universel, haute disponibilite" "$gg_tag" \
        "adguard"    "AdGuard DNS  94.140.14  - Anti-pub et trackers natif"      "$ag_tag" \
        3>&1 1>&2 2>&3) || return 1
    [[ -n "$choice" ]] && SELECTED_UPSTREAM="$choice"
    log "Upstream sélectionné: ${SELECTED_UPSTREAM}"
}

update_script() {
    msg_info "Vérification de la mise à jour du script..."
    local remote_url="https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/install_unbound_interactive.sh"
    local local_file="$0"

    if curl -fsSL "$remote_url" -o "${local_file}.tmp"; then
        local remote_version
        remote_version=$(grep -m1 'readonly SCRIPT_VERSION=' "${local_file}.tmp" | cut -d'"' -f2)
        if [[ -n "$remote_version" && "$remote_version" == "$SCRIPT_VERSION" ]]; then
            msg_ok "Déjà à jour (v${SCRIPT_VERSION})"
            rm -f "${local_file}.tmp"
            return 0
        fi
        chmod +x "${local_file}.tmp"
        mv "${local_file}.tmp" "$local_file"
        msg_ok "Mis à jour: v${SCRIPT_VERSION} → v${remote_version:-inconnue}. Relancez le script."
        exit 0
    else
        msg_error "Échec du téléchargement de la mise à jour."
        rm -f "${local_file}.tmp"
    fi
}

show_menu() {
    local choice
    while true; do
        header_info

        local ub_status agh_status
        ub_status=$(systemctl is-active unbound 2>/dev/null || echo "inactif")
        agh_status=$(systemctl is-active AdGuardHome 2>/dev/null || echo "inactif")

        local ub_dot agh_dot
        [[ "$ub_status"  == "active" ]] && ub_dot="[+]" || ub_dot="[ ]"
        [[ "$agh_status" == "active" ]] && agh_dot="[+]" || agh_dot="[ ]"

        local status_line="${ub_dot} Unbound: ${ub_status}   ${agh_dot} AdGuard: ${agh_status}   > ${SELECTED_UPSTREAM}"
        [[ "$DRY_RUN" == "true" ]] && status_line="[DRY-RUN]  ${status_line}"

        # Label dynamique selon etat d'installation
        local label_install="Installer              Installation complete"
        if [[ "$ub_status" == "active" && "$agh_status" == "active" ]]; then
            label_install="Reinstaller            Ecraser l'installation existante"
        fi

        choice=$(whiptail \
            --title " AdGuard Home + Unbound  v${SCRIPT_VERSION} " \
            --cancel-button "Quitter" \
            --ok-button "Choisir" \
            --menu "${status_line}\n\nSelectionnez une action :" 24 76 9 \
            "1" "  ${label_install}" \
            "2" "  Reparer / Reconfigurer   Unbound + AdGuard upstream" \
            "3" "  Diagnostics              Health check complet + benchmark" \
            "4" "  Statistiques Unbound     Cache, requetes, performances" \
            "5" "  MAJ Systeme              apt update + upgrade" \
            "6" "  MAJ Script               Depuis GitHub" \
            "7" "  Desinstaller             Supprimer AdGuard Home + Unbound" \
            "8" "  Quitter" \
            3>&1 1>&2 2>&3) || exit 0

        case $choice in
            1)
                STEP_TOTAL=4; STEP_CURRENT=0
                select_upstream || continue
                msg_step "Optimisations réseau (sysctl)"
                apply_sysctl_tuning
                msg_step "Installation & configuration Unbound"
                install_unbound
                msg_step "Installation AdGuard Home"
                install_adguard_home
                msg_step "Health check post-installation"
                local local_ip; local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
                local agh_port="3000"
                type get_adguard_web_port &>/dev/null && agh_port=$(get_adguard_web_port)
                STEP_TOTAL=0; STEP_CURRENT=0
                if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]] && run_full_health_check &>/dev/null; then
                    whiptail --title " Installation reussie " \
                        --msgbox "Tous les services sont actifs et vérifiés.\n\n  Upstream DNS : ${SELECTED_UPSTREAM}\n  AdGuard Home : http://${local_ip}:${agh_port}\n  Unbound      : port ${UNBOUND_PORT} (DoT)\n\nConsultez les logs : ${LOG_FILE}" 14 62
                else
                    whiptail --title " Installation terminee " \
                        --msgbox "Installation terminée (health check non concluant).\n\n  AdGuard Home : http://${local_ip}:${agh_port}\n  Upstream DNS : ${SELECTED_UPSTREAM}\n\nConsultez les logs : ${LOG_FILE}" 13 62
                fi
                ;;
            2)
                select_upstream || continue
                install_unbound
                configure_adguard_upstream
                whiptail --title " Reconfiguration appliquee " \
                    --msgbox "Unbound et AdGuard Home ont été reconfigurés.\n\n  Upstream actif : ${SELECTED_UPSTREAM}\n  Port Unbound   : ${UNBOUND_PORT}" 11 58
                ;;
            3)
                if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]]; then
                    local hc_raw hc_file
                    hc_raw=$(mktemp)
                    hc_file=$(mktemp)
                    run_full_health_check > "$hc_raw" 2>&1 || true
                    type benchmark_dns_performance &>/dev/null && benchmark_dns_performance 100 >> "$hc_raw" 2>&1 || true
                    sanitize_textbox_output < "$hc_raw" > "$hc_file"
                    whiptail --title " Diagnostics  v${SCRIPT_VERSION} " --scrolltext --textbox "$hc_file" 26 92 || true
                    rm -f "$hc_raw" "$hc_file"
                else
                    whiptail --title " Module manquant " \
                        --msgbox "lib/health_checks.sh introuvable.\nAssurez-vous de cloner le dépôt complet." 9 58
                fi
                ;;
            4)
                if command -v unbound-control &>/dev/null; then
                    local stats_file; stats_file=$(mktemp)
                    if unbound-control stats_noreset > "$stats_file" 2>&1 && [[ -s "$stats_file" ]]; then
                        whiptail --title " Statistiques Unbound " --scrolltext --textbox "$stats_file" 26 76
                    else
                        whiptail --msgbox "Statistiques non disponibles.\nUnbound est-il actif ? (systemctl status unbound)" 9 56
                    fi
                    rm -f "$stats_file"
                else
                    whiptail --msgbox "unbound-control introuvable.\nInstallez Unbound d'abord (option 1)." 9 52
                fi
                ;;
            5)
                msg_info "Mise à jour du système en cours..."
                apt-get update -qq &>/dev/null && apt-get upgrade -y -qq &>/dev/null
                msg_ok "Système à jour"
                whiptail --title " MAJ systeme " \
                    --msgbox "apt update + upgrade terminés avec succès." 8 50
                ;;
            6) update_script ;;
            7)
                if whiptail \
                    --title " Desinstallation " \
                    --yesno "Désinstaller AdGuard Home et Unbound ?\n\nTous les fichiers de configuration seront supprimés.\nCette action est irréversible." 12 60; then
                    uninstall_all
                fi
                ;;
            8) exit 0 ;;
        esac
    done
}

# --- Usage / Help ---

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install            Installation complète (AdGuard Home + Unbound)"
    echo "  --repair             Reconfigurer Unbound + AdGuard (sans réinstaller)"
    echo "  --unbound-only       Installer/reconfigurer uniquement Unbound"
    echo "  --update             Mettre à jour ce script depuis GitHub"
    echo "  --uninstall          Désinstaller AdGuard Home et Unbound"
    echo "  --health             Exécuter le health check complet"
    echo "  --stats              Afficher les stats Unbound"
    echo "  --benchmark [n]      Tester les performances DNS (défaut: ${DEFAULT_BENCHMARK_QUERIES})"
    echo "  --upstream <nom>     Forcer l'upstream (${VALID_UPSTREAMS[*]})"
    echo "  --dry-run            Simuler les actions sans modifier le système"
    echo "  --allow-proxmox-host Autoriser l'exécution sur le nœud Proxmox (déconseillé)"
    echo "  --help               Afficher cette aide"
    echo ""
    echo "Sans option: menu interactif."
    exit 0
}

# --- Entry Point ---

main() {
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

    local args=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --allow-proxmox-host) ALLOW_PROXMOX_HOST=true ;;
            *) args+=("$arg") ;;
        esac
    done
    [[ ${#args[@]} -gt 0 ]] && set -- "${args[@]}" || set --

    [[ "$DRY_RUN" == "true" ]] && msg_warn "Mode DRY-RUN actif — aucune modification système ne sera effectuée."

    check_root
    check_os
    check_proxmox_target
    check_dependencies

    if [[ "${1:-}" == "--upstream" && -n "${2:-}" ]]; then
        validate_upstream "$2" || exit 1
        SELECTED_UPSTREAM="$2"
        shift 2
    fi

    case "${1:-}" in
        --install)
            INTERACTIVE=false
            header_info
            STEP_TOTAL=3; STEP_CURRENT=0
            msg_step "Optimisations sysctl"
            apply_sysctl_tuning
            msg_step "Installation Unbound"
            install_unbound
            msg_step "Installation AdGuard Home"
            install_adguard_home
            STEP_TOTAL=0
            msg_ok "Installation terminée !"
            ;;
        --repair|--unbound-only)
            INTERACTIVE=false
            header_info
            install_unbound
            configure_adguard_upstream
            msg_ok "Unbound reconfiguré !"
            ;;
        --health)
            header_info
            if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]]; then
                run_full_health_check
            else
                msg_error "Module health_checks non disponible (lib/health_checks.sh manquant)"
                exit 1
            fi
            ;;
        --stats)
            header_info
            command -v unbound-control &>/dev/null || { msg_error "unbound-control non disponible"; exit 1; }
            unbound-control stats_noreset
            ;;
        --benchmark)
            header_info
            if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]] && type benchmark_dns_performance &>/dev/null; then
                benchmark_dns_performance "${2:-$DEFAULT_BENCHMARK_QUERIES}"
            else
                msg_error "Benchmark indisponible (lib/health_checks.sh manquant)"
                exit 1
            fi
            ;;
        --update)
            header_info
            update_script
            ;;
        --uninstall)
            header_info
            uninstall_all
            ;;
        "")
            show_menu
            ;;
        *)
            msg_error "Option inconnue: $1"
            show_help
            ;;
    esac
}

main "$@"
