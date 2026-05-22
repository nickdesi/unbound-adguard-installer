#!/usr/bin/env bash
# shellcheck disable=SC2034  # STEP_CURRENT/STEP_TOTAL used by lib/common.sh msg_info/msg_step

# ==========================================================================
# AdGuard Home & Unbound All-in-One Installer/Updater pour Proxmox LXC
# ==========================================================================
# Script inspiré du style "Proxmox VE Helper-Scripts" (tteck/community-scripts)
# Installe, configure et met à jour AdGuard Home + Unbound sur Debian/Ubuntu LXC.
# ==========================================================================
# Auteur: Nicolas
# Version: 3.4.2
# Licence: MIT
# ==========================================================================

# --- Safety & Error Handling ---
set -Eeuo pipefail

# --- Error Handling & Cleanup ---

cleanup() {
    rm -rf /tmp/agh_install /tmp/agh_update 2>/dev/null || true
}

error_handler() {
    local exit_code="$1" line_number="$2" command="$3"
    if command -v msg_error >/dev/null 2>&1; then
        msg_error "Erreur ligne ${line_number}: '${command}' a échoué (code ${exit_code})"
    else
        echo "Erreur ligne ${line_number}: '${command}' a échoué (code ${exit_code})" >&2
    fi
}

trap cleanup EXIT
trap 'error_handler $? $LINENO $BASH_COMMAND' ERR

# --- Load Shared Libraries (fail-fast) ---
# common.sh est OBLIGATOIRE — le script ne peut pas fonctionner sans.
SCRIPT_SELF="${BASH_SOURCE[0]-}"
if [[ -z "$SCRIPT_SELF" ]]; then
    SCRIPT_SELF="${0:-}"
fi

if [[ -z "$SCRIPT_SELF" || "$SCRIPT_SELF" == "bash" || "$SCRIPT_SELF" == "-bash" ]]; then
    echo "FATAL: exécution non supportée via 'bash -c' sur le script brut." >&2
    echo "Utilisez setup.sh pour bootstrapper le dépôt complet :" >&2
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)\"" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    echo "FATAL: lib/common.sh introuvable dans ${SCRIPT_DIR}/lib/" >&2
    echo "Assurez-vous de cloner le repo complet et non de télécharger le script seul." >&2
    echo "Bootstrap recommandé :" >&2
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/nickdesi/unbound-adguard-installer/main/setup.sh)\"" >&2
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
readonly SCRIPT_VERSION="3.4.2"
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
readonly UPDATE_REPO="nickdesi/unbound-adguard-installer"
readonly UPDATE_REF="main"

# Global State Variables (mutable)
INTERACTIVE=true
SELECTED_UPSTREAM="cloudflare"
DRY_RUN=false
CPU_CORES=1
RAM_MB=512
ALLOW_PROXMOX_HOST=false

# --- Version comparison helper ---
# _version_ge <v1> <v2> → retourne 0 si v1 >= v2 (utilise sort -V)
_version_ge() { printf '%s\n' "$2" "$1" | sort -V -C; }

# --- Dry-run wrapper ---
# Usage: run_cmd <cmd> [args...]
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

# Whiptail helper — disables ERR trap inside subshell (Cancel returns 1)
# Usage: var=$(whiptail_safe --title "..." --menu "..." ...) || return 1
whiptail_safe() {
    trap - ERR
    whiptail "$@" 3>&1 1>&2 2>&3
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
        | sed -E 's/[éèêëÉÈÊË]/e/g; s/[àâäÀÂÄ]/a/g; s/[ùûüÛÜ]/u/g; s/[ôöÔÖ]/o/g; s/[îïÎÏ]/i/g; s/[çÇ]/c/g' \
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
        # shellcheck disable=SC1091
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
        if download_with_retry "https://www.internic.net/domain/named.cache" "$ROOT_HINTS_FILE" 3 >/dev/null; then
            msg_ok "Root hints à jour"
        else
            msg_warn "Root hints non mis à jour"
        fi
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
    if [[ -f "$UNBOUND_TRUST_ANCHOR" ]]; then
        cp -a "$UNBOUND_TRUST_ANCHOR" "${UNBOUND_TRUST_ANCHOR}.backup.$(date +%s)"
    fi
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

# --- Auto-select fastest upstream by latency ---
# Usage: auto_benchmark_upstream
auto_benchmark_upstream() {
    local fastest="" best_ms=99999 ms name
    local -A UPSTREAM_MAP=(
        [cloudflare]="1.1.1.1"
        [quad9]="9.9.9.9"
        [google]="8.8.8.8"
        [adguard]="94.140.14.14"
        [mullvad]="194.242.2.2"
        [controld]="76.76.2.0"
        [dns0]="193.110.81.254"
    )
    local -A UPSTREAM_DISPLAY=(
        [cloudflare]="Cloudflare"
        [quad9]="Quad9"
        [google]="Google"
        [adguard]="AdGuard"
        [mullvad]="Mullvad"
        [controld]="ControlD"
        [dns0]="DNS0.eu"
    )
    msg_info "Benchmark des upstreams DoT (5 mesures par upstream)..."
    for name in "${!UPSTREAM_MAP[@]}"; do
        local ip="${UPSTREAM_MAP[$name]}"
        local times=()
        local ok=0
        for sample in 1 2 3 4 5; do
            local tstart elapsed
            tstart=$(date +%s%N)
            if dig @"$ip" google.com +short +tries=1 +timeout=2 &>/dev/null; then
                elapsed=$(( ($(date +%s%N) - tstart) / 1000000 ))
                times+=("$elapsed")
                ((++ok))
            fi
        done

        if (( ok == 0 )); then
            msg_warn "  ${UPSTREAM_DISPLAY[$name]} (${ip}) → timeout"
            continue
        fi

        local sorted=()
        mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
        local count=${#sorted[@]}
        local sum=0 t avg median p95
        for t in "${sorted[@]}"; do sum=$((sum + t)); done
        avg=$((sum / count))
        median="${sorted[$((count/2))]}"
        p95="${sorted[$(( (count * 95) / 100 ))]}"

        if (( p95 < best_ms )); then
            best_ms=$p95; fastest=$name
        fi
        msg_ok "  ${UPSTREAM_DISPLAY[$name]} (${ip}) → avg ${avg}ms | p50 ${median}ms | p95 ${p95}ms"
    done
    if [[ -n "$fastest" && "$best_ms" -lt 99999 ]]; then
        SELECTED_UPSTREAM="$fastest"
        msg_ok "Upstream sélectionné: ${UPSTREAM_DISPLAY[$fastest]} (p95 ${best_ms}ms)"
    else
        msg_warn "Benchmark échoué, garde cloudflare par défaut"
    fi
    log "Auto-upstream: ${SELECTED_UPSTREAM} (${best_ms}ms p95)"
}

# --- Network Optimization (Sysctl) ---

apply_sysctl_tuning() {
    msg_info "Application des optimisations réseau (sysctl)"
    local SYSCTL_CONF="/etc/sysctl.d/99-dns-optimization.conf"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Écriture de $SYSCTL_CONF"
        return 0
    fi
    local congestion="bbr"
    if ! sysctl -q net.ipv4.tcp_congestion_control &>/dev/null 2>&1 || \
       ! echo "bbr" | tee /proc/sys/net/ipv4/tcp_congestion_control &>/dev/null 2>&1; then
        congestion="cubic"
        msg_warn "BBR indisponible, fallback sur cubic"
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
net.ipv4.tcp_congestion_control = ${congestion}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.optmem_max = 65536
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 4096
net.ipv4.tcp_mem = 65536 131072 262144
EOF
    if sysctl -p "$SYSCTL_CONF" &>/dev/null; then
        msg_ok "Optimisations sysctl appliquées"
    else
        msg_warn "Optimisations sysctl non appliquées (LXC non-privilégié ?)"
    fi
}

# --- Unbound Logic & Calculation ---

get_cgroup_cpu_limit() {
    local quota period cpuset cpus
    if [[ -r /sys/fs/cgroup/cpu.max ]]; then
        read -r quota period < /sys/fs/cgroup/cpu.max || true
        if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && $period -gt 0 ]]; then
            cpus=$(( (quota + period - 1) / period ))
            (( cpus > 0 )) && echo "$cpus" && return 0
        fi
    elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
        quota=$(< /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        period=$(< /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && $quota -gt 0 && $period -gt 0 ]]; then
            cpus=$(( (quota + period - 1) / period ))
            (( cpus > 0 )) && echo "$cpus" && return 0
        fi
    fi

    for cpuset in /sys/fs/cgroup/cpuset.cpus.effective /sys/fs/cgroup/cpuset/cpuset.cpus.effective /sys/fs/cgroup/cpuset/cpuset.cpus; do
        [[ -r "$cpuset" ]] || continue
        count_cpuset_cpus "$(< "$cpuset")" && return 0
    done

    return 1
}

get_cgroup_ram_limit_mb() {
    local limit
    for limit in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$limit" ]] || continue
        limit=$(< "$limit")
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        (( limit > 0 && limit < 9000000000000000000 )) || continue
        echo $(( limit / 1024 / 1024 ))
        return 0
    done
    return 1
}

_RESOURCES_CACHED=false
get_system_resources() {
    [[ "$_RESOURCES_CACHED" == "true" ]] && return 0
    local detected_cpu detected_ram cgroup_cpu cgroup_ram

    detected_cpu=$(nproc 2>/dev/null || nproc --all 2>/dev/null || echo 1)
    [[ "$detected_cpu" =~ ^[0-9]+$ ]] || detected_cpu=1
    if cgroup_cpu=$(get_cgroup_cpu_limit); then
        (( cgroup_cpu > 0 && cgroup_cpu < detected_cpu )) && detected_cpu=$cgroup_cpu
    fi
    CPU_CORES=$detected_cpu

    detected_ram=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    [[ "$detected_ram" =~ ^[0-9]+$ ]] || detected_ram=512
    if cgroup_ram=$(get_cgroup_ram_limit_mb); then
        (( cgroup_ram >= 64 && cgroup_ram < detected_ram )) && detected_ram=$cgroup_ram
    fi
    RAM_MB=$detected_ram
    _RESOURCES_CACHED=true
}

calculate_optimized_settings() {
    get_system_resources

    if [[ "$INTERACTIVE" == "true" ]]; then
        if ! whiptail --title "Ressources systeme" --yesno \
            "Detecte : ${CPU_CORES} CPU, ${RAM_MB} MB RAM.\n\nUtiliser ces valeurs pour l'auto-configuration ?" 10 60; then
            local user_cpu user_ram
            if user_cpu=$(whiptail_safe --inputbox "Nombre de coeurs CPU :" 8 40 "$CPU_CORES"); then
                if [[ "$user_cpu" =~ ^[0-9]+$ ]] && (( user_cpu > 0 && user_cpu <= 256 )); then
                    CPU_CORES=$user_cpu
                else
                    msg_warn "Valeur CPU invalide. Valeur détectée conservée ($CPU_CORES)."
                fi
            fi
            if user_ram=$(whiptail_safe --inputbox "RAM en MB :" 8 40 "$RAM_MB"); then
                if [[ "$user_ram" =~ ^[0-9]+$ ]] && (( user_ram >= 64 && user_ram <= 1048576 )); then
                    RAM_MB=$user_ram
                else
                    msg_warn "Valeur RAM invalide. Valeur détectée conservée ($RAM_MB)."
                fi
            fi
        fi
    fi

    NUM_THREADS=$CPU_CORES
    if (( RAM_MB <= 1024 && NUM_THREADS > 1 )); then
        NUM_THREADS=1
    elif (( RAM_MB < 2048 && NUM_THREADS > 2 )); then
        NUM_THREADS=2
    elif (( RAM_MB < 4096 && NUM_THREADS > 4 )); then
        NUM_THREADS=4
    elif (( NUM_THREADS > 8 )); then
        NUM_THREADS=8
    fi

    CACHE_SLABS=$(get_power_of_two "$NUM_THREADS")
    (( CACHE_SLABS < 1 )) && CACHE_SLABS=1

    local reserve_mb cache_budget_mb rrset_mb msg_mb key_mb neg_mb
    reserve_mb=$(( RAM_MB / 4 ))
    (( reserve_mb < 128 )) && reserve_mb=128
    (( reserve_mb > 1024 )) && reserve_mb=1024

    cache_budget_mb=$(( RAM_MB - reserve_mb ))
    (( cache_budget_mb < 96 )) && cache_budget_mb=96
    (( cache_budget_mb > 3072 )) && cache_budget_mb=3072

    rrset_mb=$(( (cache_budget_mb * 2) / 3 ))
    (( rrset_mb < 64 )) && rrset_mb=64
    msg_mb=$(( rrset_mb / 2 ))
    (( msg_mb < 32 )) && msg_mb=32

    key_mb=$(( rrset_mb / 8 ))
    (( key_mb < 8 )) && key_mb=8
    (( key_mb > 128 )) && key_mb=128

    neg_mb=$(( msg_mb / 8 ))
    (( neg_mb < 4 )) && neg_mb=4
    (( neg_mb > 64 )) && neg_mb=64

    RRSET_CACHE_SIZE="${rrset_mb}m"
    MSG_CACHE_SIZE="${msg_mb}m"
    KEY_CACHE_SIZE="${key_mb}m"
    NEG_CACHE_SIZE="${neg_mb}m"

    if (( RAM_MB < 1536 )); then
        SO_RCVBUF="1m"; SO_SNDBUF="1m"
    elif (( RAM_MB < 4096 )); then
        SO_RCVBUF="2m"; SO_SNDBUF="2m"
    else
        local buf_mb=$(( NUM_THREADS * 2 ))
        if (( buf_mb < 4 )); then buf_mb=4; fi
        if (( buf_mb > 8 )); then buf_mb=8; fi
        SO_RCVBUF="${buf_mb}m"; SO_SNDBUF="${buf_mb}m"
    fi

    INFRA_HOSTS=$(( 10000 + (RAM_MB * 12) + (NUM_THREADS * 1000) ))
    (( INFRA_HOSTS > 100000 )) && INFRA_HOSTS=100000

    # Évalue les ports disponibles système pour caler outgoing-range
    local sys_ports_high
    sys_ports_high=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $2}' || echo 65535)
    OUTGOING_RANGE=$(( 384 + (NUM_THREADS * 196) + (RAM_MB / 8) ))
    (( OUTGOING_RANGE < 384 )) && OUTGOING_RANGE=384
    (( OUTGOING_RANGE > sys_ports_high / 2 )) && OUTGOING_RANGE=$(( sys_ports_high / 2 ))
    (( OUTGOING_RANGE > 4096 )) && OUTGOING_RANGE=4096

    QUERIES_PER_THREAD=$(( 512 + (RAM_MB / (NUM_THREADS * 4)) ))
    (( QUERIES_PER_THREAD < 512 )) && QUERIES_PER_THREAD=512
    (( QUERIES_PER_THREAD > 2048 )) && QUERIES_PER_THREAD=2048

    # EDNS buffer: plus grand = moins de truncation, plus petit = moins de fragmentation
    if (( RAM_MB >= 2048 )); then
        EDNS_BUFFER=1232
    else
        EDNS_BUFFER=512
    fi

    if (( RAM_MB < 1024 )); then
        CACHE_MIN_TTL=60
        CACHE_MAX_TTL=43200
        SERVE_EXPIRED_TTL=43200
        SERVE_EXPIRED_REPLY_TTL=30
        SERVE_EXPIRED_CLIENT_TIMEOUT=1200
    elif (( RAM_MB < 4096 )); then
        CACHE_MIN_TTL=120
        CACHE_MAX_TTL=86400
        SERVE_EXPIRED_TTL=86400
        SERVE_EXPIRED_REPLY_TTL=60
        SERVE_EXPIRED_CLIENT_TIMEOUT=1800
    else
        CACHE_MIN_TTL=180
        CACHE_MAX_TTL=172800
        SERVE_EXPIRED_TTL=172800
        SERVE_EXPIRED_REPLY_TTL=120
        SERVE_EXPIRED_CLIENT_TIMEOUT=2400
    fi

    # JOSTLE_TIMEOUT : thread unique = pas de concurrence, on veut un timeout bas
    # target-fetch-policy: moins agressif sur mono-cœur
    if (( NUM_THREADS <= 1 )); then
        TARGET_FETCH_POLICY='"1 0 0 0 0 0"'
    else
        TARGET_FETCH_POLICY='"2 1 0 0 0 0"'
    fi

    # infra-host-ttl : plus de infohosts = ttl plus long pour stabiliser
    if (( INFRA_HOSTS >= 50000 )); then
        INFRA_HOST_TTL=1800
    else
        INFRA_HOST_TTL=900
    fi

    JOSTLE_TIMEOUT=$(( 80 + (NUM_THREADS * 30) + (RAM_MB / 512) ))
    (( JOSTLE_TIMEOUT < 80 )) && JOSTLE_TIMEOUT=80
    (( JOSTLE_TIMEOUT > 500 )) && JOSTLE_TIMEOUT=500

    # unwanted-reply-threshold : plus de RAM = plus de tolérance au trafic erroné
    if (( RAM_MB >= 4096 )); then
        UNWANTED_REPLY_THRESHOLD=10000000
    elif (( RAM_MB >= 1024 )); then
        UNWANTED_REPLY_THRESHOLD=1000000
    else
        UNWANTED_REPLY_THRESHOLD=10000
    fi

    # TCP concurrency: mono-cœur épuise vite 10 connexions entrantes par défaut
    if (( NUM_THREADS <= 1 )); then
        INCOMING_NUM_TCP=3; OUTGOING_NUM_TCP=5; RATELIMIT_VAL=200
    elif (( NUM_THREADS <= 3 )); then
        INCOMING_NUM_TCP=5; OUTGOING_NUM_TCP=10; RATELIMIT_VAL=500
    else
        INCOMING_NUM_TCP=10; OUTGOING_NUM_TCP=20; RATELIMIT_VAL=1000
    fi

    # NSEC agressif = requêtes supplémentaires, gaspillage sur faible RAM
    AGGRESSIVE_NSEC="yes"
    (( RAM_MB < 1024 )) && AGGRESSIVE_NSEC="no"

    SO_REUSEPORT="yes"
    if (( NUM_THREADS == 1 )); then
        SO_REUSEPORT="no"
    fi
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

    local UNBOUND_VER
    UNBOUND_VER="$(unbound -V 2>/dev/null | head -1 | sed 's/.*Version //')"
    local _HAS_DO_TCP_KEEPALIVE=false _HAS_FORWARD_NO_AAAA=false
    if [[ -n "$UNBOUND_VER" ]] && _version_ge "$UNBOUND_VER" "1.19.0" && ! _version_ge "$UNBOUND_VER" "1.21.0"; then
        _HAS_DO_TCP_KEEPALIVE=true
        _HAS_FORWARD_NO_AAAA=true
        msg_ok "Unbound ${UNBOUND_VER} — toutes les fonctionnalités avancées supportées"
    else
        msg_info "Unbound ${UNBOUND_VER:-?} — fonctionnalités avancées limitées (do-tcp-keepalive/forward-no-aaaa désactivés)"
    fi

    local _TCP_FEATURES
    if [[ "$_HAS_DO_TCP_KEEPALIVE" == "true" ]]; then
        _TCP_FEATURES=$'    do-tcp-keepalive: yes\n    tcp-idle-timeout: 120\n    edns-tcp-keepalive-timeout: 120\n    val-clean-additional: yes'
    else
        _TCP_FEATURES=$'    tcp-idle-timeout: 120\n    edns-tcp-keepalive-timeout: 120\n    val-clean-additional: yes'
    fi

    local _FORWARD_NO_AAAA=""
    [[ "$_HAS_FORWARD_NO_AAAA" == "true" ]] && _FORWARD_NO_AAAA="    forward-no-aaaa: yes"

    msg_info "Génération de la configuration Unbound (Threads: $NUM_THREADS, Slabs: $CACHE_SLABS)"

    local _UPSTREAM_LINES _UPSTREAM_BACKUP
    case "$SELECTED_UPSTREAM" in
        cloudflare)
            _UPSTREAM_LINES=$'    forward-addr: 1.1.1.1@853#cloudflare-dns.com\n    forward-addr: 1.0.0.1@853#cloudflare-dns.com'
            _UPSTREAM_BACKUP=$'    forward-addr: 9.9.9.9@853#dns.quad9.net'
            ;;
        quad9)
            _UPSTREAM_LINES=$'    forward-addr: 9.9.9.9@853#dns.quad9.net\n    forward-addr: 149.112.112.112@853#dns.quad9.net'
            _UPSTREAM_BACKUP=$'    forward-addr: 1.1.1.1@853#cloudflare-dns.com'
            ;;
        google)
            _UPSTREAM_LINES=$'    forward-addr: 8.8.8.8@853#dns.google\n    forward-addr: 8.8.4.4@853#dns.google'
            _UPSTREAM_BACKUP=$'    forward-addr: 1.1.1.1@853#cloudflare-dns.com'
            ;;
        adguard)
            _UPSTREAM_LINES=$'    forward-addr: 94.140.14.14@853#dns.adguard.com\n    forward-addr: 94.140.15.15@853#dns.adguard.com'
            _UPSTREAM_BACKUP=$'    forward-addr: 1.1.1.1@853#cloudflare-dns.com'
            ;;
        *)
            _UPSTREAM_LINES=$'    forward-addr: 1.1.1.1@853#cloudflare-dns.com\n    forward-addr: 1.0.0.1@853#cloudflare-dns.com'
            _UPSTREAM_BACKUP=$'    forward-addr: 9.9.9.9@853#dns.quad9.net'
            ;;
    esac

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p /etc/unbound/unbound.conf.d /var/lib/unbound
        cat > "${UNBOUND_CONF}.tmp" <<'EOF'
include: "/etc/unbound/unbound.conf.d/*.conf"
EOF
        mv "${UNBOUND_CONF}.tmp" "$UNBOUND_CONF"
        cat > "${UNBOUND_CONF_NEW}.tmp" <<EOF
server:
    verbosity: 0
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
    key-cache-size: ${KEY_CACHE_SIZE}
    neg-cache-size: ${NEG_CACHE_SIZE}

    jostle-timeout: ${JOSTLE_TIMEOUT}
    target-fetch-policy: ${TARGET_FETCH_POLICY}
    infra-host-ttl: ${INFRA_HOST_TTL}

    # --- Réseau ---
    so-reuseport: ${SO_REUSEPORT}
    so-rcvbuf: ${SO_RCVBUF}
    so-sndbuf: ${SO_SNDBUF}
    edns-buffer-size: ${EDNS_BUFFER}
    max-udp-size: ${EDNS_BUFFER}
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
    serve-expired-reply-ttl: ${SERVE_EXPIRED_REPLY_TTL}
    prefetch: yes
    prefetch-key: yes
    aggressive-nsec: yes
    serve-original-ttl: yes
    unwanted-reply-threshold: ${UNWANTED_REPLY_THRESHOLD}

    # --- TCP & Connexions avancées ---
    incoming-num-tcp: ${INCOMING_NUM_TCP}
    outgoing-num-tcp: ${OUTGOING_NUM_TCP}
${_TCP_FEATURES}
    ratelimit: ${RATELIMIT_VAL}

    # --- Sécurité & Vie privée ---
    aggressive-nsec: ${AGGRESSIVE_NSEC}
    hide-identity: yes
    hide-version: yes
    deny-any: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-algo-downgrade: yes
    qname-minimisation: yes
    use-caps-for-id: no
    private-address: 192.168.0.0/16
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12

    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

forward-zone:
    name: "."
    forward-tls-upstream: yes
${_FORWARD_NO_AAAA}
    ${_UPSTREAM_LINES}
    ${_UPSTREAM_BACKUP}

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

    if [[ "$DRY_RUN" == "true" ]]; then
        msg_ok "[DRY-RUN] Configuration Unbound simulée"
        return 0
    fi

    refresh_root_hints_if_needed

    if [[ ! -f "/etc/unbound/unbound_server.key" ]]; then
        msg_info "Génération des clés de contrôle Unbound"
        unbound-control-setup &>/dev/null || true
    fi

    [[ -s "$UNBOUND_TRUST_ANCHOR" ]] || repair_unbound_trust_anchor || true
    chown -R unbound:unbound /etc/unbound /var/lib/unbound
    chmod 755 /etc/unbound /etc/unbound/unbound.conf.d /var/lib/unbound
    chmod 640 /etc/unbound/unbound_control.* 2>/dev/null || true
    chmod 644 "$ROOT_HINTS_FILE" 2>/dev/null || true

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

        # Cache persistence: dump on stop, load on start
        mkdir -p /etc/systemd/system/unbound.service.d
        cat > /etc/systemd/system/unbound.service.d/cache-persist.conf <<'CACHEEOF'
[Service]
ExecStartPre=-/bin/sh -c '/usr/sbin/unbound-control -s 127.0.0.1@8953 load_cache < /var/lib/unbound/cache.dump 2>/dev/null || true'
ExecStop=-/bin/sh -c '/usr/sbin/unbound-control -s 127.0.0.1@8953 dump_cache > /var/lib/unbound/cache.dump 2>/dev/null || true'
CACHEEOF
        systemctl daemon-reload &>/dev/null

        restart_service_safely unbound 30 || { msg_error "Échec redémarrage sécurisé Unbound"; exit 1; }
        msg_ok "Configuration Unbound valide et service redémarré"

        prewarm_unbound_cache
    else
        msg_error "Configuration Unbound invalide !"
        printf '%s\n' "$checkconf_output"
        exit 1
    fi
}



# --- Cache Pre-warming ---

prewarm_unbound_cache() {
    [[ "$DRY_RUN" == "true" ]] && { echo "  [DRY-RUN] Cache pre-warming"; return 0; }

    msg_info "Préchauffage du cache Unbound..."

    local domains=()

    # Try to read top domains from AdGuard Home query log
    local agh_log="/opt/AdGuardHome/data/querylog.json"
    if [[ -f "$agh_log" ]] && command -v jq &>/dev/null; then
        local log_domains
        log_domains=$(jq -r 'select(.Q != null) | .Q' "$agh_log" 2>/dev/null | \
            sed 's/.*@//' | awk -F. '{if(NF>=2) print $(NF-1)"."$NF}' | \
            sort | uniq -c | sort -rn | head -40 | awk '{print $2}')
        if [[ -n "$log_domains" ]]; then
            while IFS= read -r d; do
                domains+=("$d")
            done <<< "$log_domains"
        fi
    fi

    # Fallback to static common domains
    if [[ ${#domains[@]} -eq 0 ]]; then
        domains=(
            google.com www.google.com dns.google.com
            cloudflare.com www.cloudflare.com 1.1.1.1
            github.com api.github.com raw.githubusercontent.com
            facebook.com www.facebook.com
            amazon.com www.amazon.com aws.amazon.com
            microsoft.com www.microsoft.com login.microsoftonline.com
            apple.com www.apple.com icloud.com
            netflix.com www.netflix.com
            twitter.com x.com t.co
            youtube.com www.youtube.com
            wikipedia.org en.wikipedia.org
            reddit.com www.reddit.com
            stackoverflow.com cdn.sstatic.net
            npmjs.com registry.npmjs.org
            docker.com hub.docker.com
            debian.org security.debian.org
            ubuntu.com archive.ubuntu.com
        )
    fi

    local warmed=0 failed=0
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=()
    local i=0 domain

    for domain in "${domains[@]}"; do
        (
            if dig @127.0.0.1 -p "${UNBOUND_PORT}" +short "${domain}" &>/dev/null; then
                echo "ok" > "${tmp_dir}/${i}"
            else
                echo "fail" > "${tmp_dir}/${i}"
            fi
        ) &
        pids+=("$!")
        i=$((i+1))
        # Batch in groups of 10 to avoid overwhelming
        if (( ${#pids[@]} >= 10 )); then
            wait "${pids[@]}" 2>/dev/null || true
            pids=()
        fi
    done
    wait "${pids[@]}" 2>/dev/null || true

    for result in "${tmp_dir}"/*; do
        if [[ -f "$result" ]]; then
            if [[ "$(cat "$result")" == "ok" ]]; then
                warmed=$((warmed+1))
            else
                failed=$((failed+1))
            fi
        fi
    done
    rm -rf "$tmp_dir"

    msg_ok "Cache préchauffé: ${warmed}/${#domains[@]} domaines résolus (${failed} échecs)"
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
    config['dns']['bootstrap_dns'] = ['1.1.1.1']
    config['dns']['enable_dnssec'] = True
    config['dns']['cache_size'] = 0
    config['dns']['cache_ttl_min'] = max(int(config['dns'].get('cache_ttl_min') or 0), 120)
    config['dns']['cache_ttl_max'] = max(int(config['dns'].get('cache_ttl_max') or 0), 86400)
    config['dns']['optimistic_cache'] = True
    config['dns']['disable_ipv6'] = True
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
    local LATEST_VER="${_AGH_VER:-inconnue}"

    if [[ -f "$AGH_BINARY" ]]; then
        msg_ok "AdGuard Home déjà installé (idempotent)"
        configure_adguard_upstream
        return 0
    fi

    check_disk_space /opt 150 || { msg_error "Espace disque insuffisant (150 MB requis)"; return 1; }

    if [[ ! -f "/tmp/agh_install/AGH.tar.gz" ]]; then
        msg_info "Détection architecture..."
        local AGH_ARCH
        AGH_ARCH=$(get_agh_arch) || { msg_error "Architecture non supportée: $(uname -m)"; exit 1; }
        msg_info "Récupération de la dernière version AdGuard Home..."
        LATEST_VER="${_AGH_VER:-}"
        if [[ -z "$LATEST_VER" ]]; then
            LATEST_VER=$(fetch_json_api "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.tag_name')
        fi
        if [[ -z "$LATEST_VER" || "$LATEST_VER" == "null" ]]; then
            msg_error "Impossible de trouver la dernière version AdGuard Home"
            exit 1
        fi
        _AGH_VER="$LATEST_VER"
        local url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VER}/AdGuardHome_linux_${AGH_ARCH}.tar.gz"
        if [[ "$DRY_RUN" == "true" ]]; then
            msg_ok "[DRY-RUN] Téléchargement simulé: $url"
            return 0
        fi
        download_adguard_release_tarball "$LATEST_VER" "$AGH_ARCH" "/tmp/agh_install/AGH.tar.gz" || {
            msg_error "Échec téléchargement AdGuard Home"; return 1
        }
    elif [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

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
            if check_adguard_health &>/dev/null; then
                msg_ok "Health check: OK"
            else
                msg_warn "Health check: voir logs"
            fi
        fi
    else
        msg_warn "Fichier YAML non trouvé, configuration manuelle requise"
    fi
}

reset_adguard_password() {
    if [[ ! -f "$AGH_YAML" ]]; then
        whiptail --title " AdGuard Home " \
            --msgbox "Configuration introuvable :\n${AGH_YAML}\n\nInstallez AdGuard Home d'abord." 10 62
        return 1
    fi

    local username password password_confirm password_hash
    username=$(whiptail_safe \
        --title " Reset mot de passe AdGuard " \
        --inputbox "Utilisateur AdGuard a reinitialiser :" 9 58 "admin") || return 1

    if [[ -z "$username" ]]; then
        whiptail --title " Reset annule " --msgbox "Le nom d'utilisateur ne peut pas etre vide." 8 54
        return 1
    fi

    password=$(whiptail_safe \
        --title " Nouveau mot de passe " \
        --passwordbox "Saisissez le nouveau mot de passe :" 9 58) || return 1
    password_confirm=$(whiptail_safe \
        --title " Confirmation " \
        --passwordbox "Confirmez le nouveau mot de passe :" 9 58) || return 1

    if [[ -z "$password" ]]; then
        whiptail --title " Reset annule " --msgbox "Le mot de passe ne peut pas etre vide." 8 54
        return 1
    fi

    if [[ "$password" != "$password_confirm" ]]; then
        whiptail --title " Reset annule " --msgbox "Les mots de passe ne correspondent pas." 8 54
        return 1
    fi

    msg_info "Réinitialisation du mot de passe AdGuard Home..."

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Reset du mot de passe AdGuard pour l'utilisateur ${username}"
        return 0
    fi

    if ! command -v htpasswd &>/dev/null; then
        msg_info "Installation de apache2-utils pour générer le hash bcrypt..."
        apt-get update -qq &>/dev/null || true
        apt-get install -y --no-install-recommends apache2-utils &>/dev/null
    fi

    command -v htpasswd &>/dev/null || { msg_error "htpasswd introuvable"; return 1; }

    password_hash=$(printf '%s\n' "$password" | htpasswd -niB -C 10 "$username" | cut -d: -f2-)
    [[ -n "$password_hash" ]] || { msg_error "Échec génération du hash bcrypt"; return 1; }

    create_backup "$AGH_YAML" || true

    AGH_YAML="$AGH_YAML" AGH_RESET_USER="$username" AGH_RESET_HASH="$password_hash" python3 - <<'PYTHON'
import os
import sys
import yaml

path = os.environ.get("AGH_YAML", "/opt/AdGuardHome/AdGuardHome.yaml")
username = os.environ["AGH_RESET_USER"]
password_hash = os.environ["AGH_RESET_HASH"]

try:
    with open(path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f) or {}

    users = config.get("users")
    if not isinstance(users, list):
        users = []
        config["users"] = users

    for user in users:
        if isinstance(user, dict) and user.get("name") == username:
            user["password"] = password_hash
            break
    else:
        users.append({"name": username, "password": password_hash})

    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
except Exception as exc:
    print(f"ERREUR: {exc}", file=sys.stderr)
    sys.exit(1)
PYTHON

    restart_service_safely AdGuardHome 30 || true
    msg_ok "Mot de passe AdGuard Home réinitialisé pour ${username}"
}

# --- Uninstall Logic ---

uninstall_all() {
    if ! whiptail --title "Desinstallation" --yesno \
        "Voulez-vous vraiment desinstaller AdGuard Home et Unbound ?\nLes fichiers de configuration seront supprimes." 10 60; then
        return 0
    fi

    msg_info "Suppression AdGuard Home..."
    systemctl stop AdGuardHome &>/dev/null || true
    if [[ -x "$AGH_BINARY" ]]; then
        "$AGH_BINARY" -s uninstall &>/dev/null || true
    fi
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
    local term_cols term_lines menu_width menu_height list_height
    cf_tag="OFF"; q9_tag="OFF"; gg_tag="OFF"; ag_tag="OFF"
    case "$SELECTED_UPSTREAM" in
        cloudflare) cf_tag="ON" ;;
        quad9)      q9_tag="ON" ;;
        google)     gg_tag="ON" ;;
        adguard)    ag_tag="ON" ;;
    esac

    term_cols=$(tput cols 2>/dev/null || echo 80)
    term_lines=$(tput lines 2>/dev/null || echo 24)

    menu_width=$((term_cols - 6))
    (( menu_width > 90 )) && menu_width=90
    (( menu_width < 56 )) && menu_width=56

    menu_height=$((term_lines - 6))
    (( menu_height > 20 )) && menu_height=20
    (( menu_height < 13 )) && menu_height=13

    list_height=4

    local choice
    choice=$(whiptail_safe \
        --title " DNS-over-TLS Upstream (port 853) " \
        --ok-button "Confirmer" \
        --cancel-button "Annuler" \
        --radiolist "Choisissez le fournisseur upstream :\n(Espace pour selectionner, Entree pour confirmer)" "$menu_height" "$menu_width" "$list_height" \
        "cloudflare" "1.1.1.1   Rapide, sans log" "$cf_tag" \
        "quad9"      "9.9.9.9   DNSSEC strict" "$q9_tag" \
        "google"     "8.8.8.8   Universel" "$gg_tag" \
        "adguard"    "94.140.14.14   Anti-pub/trackers" "$ag_tag") || return 1
    [[ -n "$choice" ]] && SELECTED_UPSTREAM="$choice"
    log "Upstream sélectionné: ${SELECTED_UPSTREAM}"
}

update_script() {
    msg_info "Mise à jour du dépôt local (script + lib)..."

    local archive_url="https://codeload.github.com/${UPDATE_REPO}/tar.gz/${UPDATE_REF}"
    local tmp_dir tmp_tar remote_version
    tmp_dir=$(mktemp -d /tmp/agh_update.XXXXXX)
    tmp_tar="${tmp_dir}/repo.tar.gz"

    if ! download_with_retry "$archive_url" "$tmp_tar" 3; then
        msg_error "Échec du téléchargement de la mise à jour"
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -tzf "$tmp_tar" >/dev/null 2>&1 || {
        msg_error "Archive de mise à jour invalide"
        rm -rf "$tmp_dir"
        return 1
    }

    tar -xzf "$tmp_tar" -C "$tmp_dir" --strip-components=1
    remote_version=$(grep -m1 'readonly SCRIPT_VERSION=' "${tmp_dir}/install_unbound_interactive.sh" | cut -d'"' -f2)

    if [[ -n "$remote_version" && "$remote_version" == "$SCRIPT_VERSION" ]]; then
        msg_ok "Déjà à jour (v${SCRIPT_VERSION})"
        rm -rf "$tmp_dir"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        local local_sha remote_sha
        local_sha=$(sha256sum "$tmp_tar" | awk '{print $1}')
        remote_sha=$(fetch_json_api "https://api.github.com/repos/${UPDATE_REPO}/git/ref/heads/${UPDATE_REF}" | jq -r '.object.sha // empty' 2>/dev/null || true)
        echo "  [DRY-RUN] SHA256 archive: ${local_sha}"
        [[ -n "$remote_sha" ]] && echo "  [DRY-RUN] Commit distant: ${remote_sha:0:7}"
        echo "  [DRY-RUN] Copie ${tmp_dir}/install_unbound_interactive.sh -> ${SCRIPT_DIR}/install_unbound_interactive.sh"
        echo "  [DRY-RUN] Copie ${tmp_dir}/setup.sh -> ${SCRIPT_DIR}/setup.sh"
        echo "  [DRY-RUN] Copie ${tmp_dir}/lib/*.sh -> ${SCRIPT_DIR}/lib/"
        rm -rf "$tmp_dir"
        msg_ok "Mise à jour simulée"
        return 0
    fi

    [[ -f "${tmp_dir}/install_unbound_interactive.sh" && -f "${tmp_dir}/setup.sh" && -f "${tmp_dir}/lib/common.sh" ]] || {
        msg_error "Archive incomplète: fichiers requis manquants"
        rm -rf "$tmp_dir"
        return 1
    }

    cp "${tmp_dir}/install_unbound_interactive.sh" "${SCRIPT_DIR}/install_unbound_interactive.sh"
    cp "${tmp_dir}/setup.sh" "${SCRIPT_DIR}/setup.sh"
    cp "${tmp_dir}/lib/common.sh" "${SCRIPT_DIR}/lib/common.sh"
    if [[ -f "${tmp_dir}/lib/health_checks.sh" ]]; then
        cp "${tmp_dir}/lib/health_checks.sh" "${SCRIPT_DIR}/lib/health_checks.sh"
    fi
    chmod +x "${SCRIPT_DIR}/install_unbound_interactive.sh" "${SCRIPT_DIR}/setup.sh"

    rm -rf "$tmp_dir"
    msg_ok "Mis à jour: v${SCRIPT_VERSION} → v${remote_version:-inconnue}. Relancez le script."
}

update_unbound_daemon() {
    [[ "$DRY_RUN" == "true" ]] && { echo "  [DRY-RUN] Mise à jour Unbound simulée"; return 0; }

    local current_ver
    current_ver="$(unbound -V 2>/dev/null | head -1 | sed 's/.*Version //')"

    msg_info "Mise à jour d'Unbound via apt..."

    apt-get update >> "$LOG_FILE" 2>&1 || { msg_error "Échec d'apt update"; return 1; }

    local avail_ver
    avail_ver=$(apt-cache policy unbound 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
    [[ -z "$avail_ver" ]] && { msg_error "Impossible de déterminer la version disponible"; return 1; }

    if [[ -n "$current_ver" ]] && dpkg --compare-versions "$current_ver" ge "$avail_ver"; then
        msg_ok "Unbound déjà à jour (v${current_ver})"
        return 0
    fi

    apt-get install --only-upgrade -y unbound ca-certificates dnsutils >> "$LOG_FILE" 2>&1 || {
        msg_error "Échec de la mise à jour Unbound"
        return 1
    }

    msg_ok "Unbound mis à jour: ${current_ver:-?} → ${avail_ver}"
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

        choice=$(whiptail_safe \
            --title " AdGuard Home + Unbound  v${SCRIPT_VERSION} " \
            --cancel-button "Quitter" \
            --ok-button "Choisir" \
            --menu "${status_line}\n\nSelectionnez une action :" 26 76 11 \
            "1" "  ${label_install}" \
            "2" "  Reparer / Reconfigurer   Unbound + AdGuard upstream" \
            "3" "  Diagnostics              Health check complet + benchmark" \
            "4" "  Statistiques Unbound     Cache, requetes, performances" \
            "5" "  MAJ Unbound              apt upgrade vers derniere version dispo" \
            "6" "  MAJ Systeme              apt update + upgrade" \
            "7" "  MAJ Script               Depuis GitHub" \
            "8" "  Reset mot de passe       AdGuard Home" \
            "9" "  Desinstaller             Supprimer AdGuard Home + Unbound" \
            "10" "  Auto-Upstream            Benchmark DoT + selection auto" \
            "11" " Quitter") || exit 0

        case $choice in
                1)
                    STEP_TOTAL=4; STEP_CURRENT=0
                    select_upstream || continue
                    _prefetch_adguard &
                    msg_step "Optimisations réseau (sysctl)"
                    apply_sysctl_tuning
                    msg_step "Installation & configuration Unbound"
                    install_unbound
                    msg_step "Installation AdGuard Home"
                    wait 2>/dev/null || true
                    install_adguard_home
                msg_step "Health check post-installation"
                local local_ip; local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
                local agh_port="3000"
                type get_adguard_web_port &>/dev/null && agh_port=$(get_adguard_web_port)
                STEP_TOTAL=0; STEP_CURRENT=0
                if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]] && run_full_health_check &>/dev/null; then
                    whiptail --title " Installation reussie " \
                        --msgbox "Tous les services sont actifs et verifies.\n\n  Upstream DNS : ${SELECTED_UPSTREAM}\n  AdGuard Home : http://${local_ip}:${agh_port}\n  Unbound      : port ${UNBOUND_PORT} (DoT)\n\nConsultez les logs : ${LOG_FILE}" 14 62
                else
                    whiptail --title " Installation terminee " \
                        --msgbox "Installation terminee (health check non concluant).\n\n  AdGuard Home : http://${local_ip}:${agh_port}\n  Upstream DNS : ${SELECTED_UPSTREAM}\n\nConsultez les logs : ${LOG_FILE}" 13 62
                fi
                ;;
            2)
                select_upstream || continue
                install_unbound
                configure_adguard_upstream
                whiptail --title " Reconfiguration appliquee " \
                    --msgbox "Unbound et AdGuard Home ont ete reconfigures.\n\n  Upstream actif : ${SELECTED_UPSTREAM}\n  Port Unbound   : ${UNBOUND_PORT}" 11 58
                ;;
            3)
                if [[ "$HEALTH_CHECKS_AVAILABLE" == "true" ]]; then
                    local hc_raw hc_file
                    hc_raw=$(mktemp)
                    hc_file=$(mktemp)
                    run_full_health_check > "$hc_raw" 2>&1 || true
                    if type benchmark_dns_performance &>/dev/null; then
                        benchmark_dns_performance 100 >> "$hc_raw" 2>&1 || true
                    fi
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
                update_unbound_daemon
                ;;
            6)
                msg_info "Mise à jour du système en cours..."
                apt-get update -qq && apt-get upgrade -y -qq --no-install-recommends
                msg_ok "Système à jour"
                whiptail --title " MAJ systeme " \
                    --msgbox "apt update + upgrade termines avec succes." 8 50
                ;;
            7) update_script ;;
            8)
                if reset_adguard_password; then
                    whiptail --title " Reset mot de passe " \
                        --msgbox "Mot de passe AdGuard Home mis a jour.\n\nReconnectez-vous a l'interface web avec le nouveau mot de passe." 10 62
                fi
                ;;
            9)
                if whiptail \
                    --title " Desinstallation " \
                    --yesno "Desinstaller AdGuard Home et Unbound ?\n\nTous les fichiers de configuration seront supprimes.\nCette action est irreversible." 12 60; then
                    uninstall_all
                fi
                ;;
            10)
                auto_benchmark_upstream
                msg_info "Application du nouvel upstream: ${SELECTED_UPSTREAM}"
                install_unbound
                configure_adguard_upstream
                whiptail --title " Auto-Upstream " \
                    --msgbox "Upstream selectionne: ${SELECTED_UPSTREAM}\n\nUnbound et AdGuard Home reconfigures automatiquement." 10 58
                ;;
            11) exit 0 ;;
        esac
    done
}

# --- Usage / Help ---

show_help() {
    echo -e "${BL}Usage:${CL} $0 [OPTIONS]"
    echo ""
    echo -e "${GN}Options:${CL}"
    echo -e "  ${YW}--install${CL}            Installation complète (AdGuard Home + Unbound)"
    echo -e "  ${YW}--repair${CL}             Reconfigurer Unbound + AdGuard (sans réinstaller)"
    echo -e "  ${YW}--unbound-only${CL}       Installer/reconfigurer uniquement Unbound"
    echo -e "  ${YW}--update-unbound${CL}     Mettre à jour Unbound via apt (version distro)"
    echo -e "  ${YW}--update${CL}             Mettre à jour ce script depuis GitHub"
    echo -e "  ${YW}--uninstall${CL}          Désinstaller AdGuard Home et Unbound"
    echo -e "  ${YW}--health${CL}             Exécuter le health check complet"
    echo -e "  ${YW}--stats${CL}              Afficher les stats Unbound"
    echo -e "  ${YW}--benchmark${CL} [n]      Tester les performances DNS (défaut: ${DEFAULT_BENCHMARK_QUERIES})"
    echo -e "  ${YW}--upstream${CL} <nom>     Forcer l'upstream (${VALID_UPSTREAMS[*]})"
    echo -e "  ${YW}--auto-upstream${CL}       Sélectionner le plus rapide par benchmark DoT"
    echo -e "  ${YW}--dry-run${CL}            Simuler les actions sans modifier le système"
    echo -e "  ${YW}--allow-proxmox-host${CL} Autoriser l'exécution sur le nœud Proxmox (déconseillé)"
    echo -e "  ${YW}--help${CL}               Afficher cette aide"
    echo ""
    echo -e "Sans option: menu interactif."
    exit 0
}

_AGH_VER=""
get_agh_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        *) return 1 ;;
    esac
}

get_adguard_release_checksum() {
    local version="$1" file_name="$2"
    local release_json checksums_url checksums_file checksum

    release_json=$(fetch_json_api "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/tags/${version}") || return 1
    checksums_url=$(jq -r '.assets[]? | select(.name | test("checksums?\\.txt$"; "i")) | .browser_download_url' <<< "$release_json" | head -n1)
    [[ -n "$checksums_url" && "$checksums_url" != "null" ]] || return 1

    checksums_file=$(mktemp /tmp/agh_checksums.XXXXXX)
    if ! download_with_retry "$checksums_url" "$checksums_file" 3 >/dev/null; then
        rm -f "$checksums_file"
        return 1
    fi

    checksum=$(grep -F "$file_name" "$checksums_file" | head -n1 | grep -Eo '[a-fA-F0-9]{64}' | head -n1)
    rm -f "$checksums_file"

    [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
    echo "$checksum"
}

download_adguard_release_tarball() {
    local version="$1" agh_arch="$2" output_file="$3"
    local file_name checksum url

    file_name="AdGuardHome_linux_${agh_arch}.tar.gz"
    url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${version}/${file_name}"
    checksum=$(get_adguard_release_checksum "$version" "$file_name") || {
        msg_error "Checksum officiel introuvable pour ${file_name} (${version})"
        return 1
    }

    download_with_retry "$url" "$output_file" 3 "$checksum"
}

_prefetch_adguard() {
    [[ -f "$AGH_BINARY" ]] && return 0
    local agh_arch
    agh_arch=$(get_agh_arch) || return 1
    local ver
    ver=$(fetch_json_api "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | jq -r '.tag_name')
    [[ -z "$ver" || "$ver" == "null" ]] && return 1
    mkdir -p /tmp/agh_install
    download_adguard_release_tarball "$ver" "$agh_arch" "/tmp/agh_install/AGH.tar.gz" && _AGH_VER="$ver"
}

# --- Entry Point ---

main() {
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

    local command="" benchmark_queries="$DEFAULT_BENCHMARK_QUERIES"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --allow-proxmox-host)
                ALLOW_PROXMOX_HOST=true
                shift
                ;;
            --upstream)
                [[ -n "${2:-}" ]] || { msg_error "--upstream requiert une valeur"; exit 1; }
                validate_upstream "$2" || exit 1
                SELECTED_UPSTREAM="$2"
                shift 2
                ;;
            --auto-upstream)
                auto_benchmark_upstream
                shift
                ;;
            --benchmark)
                [[ -z "$command" ]] || { msg_error "Plusieurs commandes détectées"; exit 1; }
                command="--benchmark"
                if [[ -n "${2:-}" && ! "${2:-}" =~ ^-- ]]; then
                    benchmark_queries="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --install|--repair|--unbound-only|--health|--stats|--update|--uninstall|--update-unbound)
                [[ -z "$command" ]] || { msg_error "Plusieurs commandes détectées"; exit 1; }
                command="$1"
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                msg_error "Option inconnue: $1"
                show_help
                ;;
        esac
    done

    [[ "$DRY_RUN" == "true" ]] && msg_warn "Mode DRY-RUN actif — aucune modification système ne sera effectuée."

    check_root
    check_os
    check_proxmox_target
    check_dependencies

    case "$command" in
        --install)
            INTERACTIVE=false
            header_info
            STEP_TOTAL=4; STEP_CURRENT=0
            msg_step "Benchmark upstream DNS"
            auto_benchmark_upstream
            _prefetch_adguard &
            msg_step "Optimisations sysctl"
            apply_sysctl_tuning
            msg_step "Installation Unbound"
            install_unbound
            msg_step "Installation AdGuard Home"
            wait 2>/dev/null || true
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
                benchmark_dns_performance "$benchmark_queries"
            else
                msg_error "Benchmark indisponible (lib/health_checks.sh manquant)"
                exit 1
            fi
            ;;
        --update)
            header_info
            update_script
            ;;
        --update-unbound)
            header_info
            update_unbound_daemon
            ;;
        --uninstall)
            header_info
            uninstall_all
            ;;
        "")
            show_menu
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
