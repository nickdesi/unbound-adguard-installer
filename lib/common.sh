#!/usr/bin/env bash
# ==========================================================================
# Common Library Functions for AdGuard Home & Unbound Installer
# ==========================================================================
# Shared utilities for error handling, validation, and network operations
# Source this file: source "$(dirname "$0")/lib/common.sh"
# ==========================================================================

# Prevent double-sourcing
[[ -n "${_COMMON_LIB_LOADED:-}" ]] && return 0
readonly _COMMON_LIB_LOADED=1

# ==========================================================================
# NETWORK UTILITIES WITH RETRY LOGIC
# ==========================================================================

# Download file with retry logic and checksum validation
# Usage: download_with_retry <url> <output_file> [max_retries] [checksum]
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-3}"
    local expected_checksum="${4:-}"
    local retry_count=0
    local download_success=false
    
    while (( retry_count < max_retries )); do
        if wget -q --show-progress -O "$output" "$url" 2>&1; then
            # Verify checksum if provided
            if [[ -n "$expected_checksum" ]]; then
                local actual_checksum
                actual_checksum=$(sha256sum "$output" | awk '{print $1}')
                if [[ "$actual_checksum" == "$expected_checksum" ]]; then
                    download_success=true
                    break
                else
                    msg_warn "Checksum mismatch (tentative $((retry_count + 1))/$max_retries)"
                    rm -f "$output"
                fi
            else
                download_success=true
                break
            fi
        fi
        
        ((retry_count++))
        if (( retry_count < max_retries )); then
            msg_warn "Échec téléchargement, nouvelle tentative dans 3s... ($retry_count/$max_retries)"
            sleep 3
        fi
    done
    
    if [[ "$download_success" != "true" ]]; then
        msg_error "Échec téléchargement après $max_retries tentatives: $url"
        return 1
    fi
    
    return 0
}

# Fetch JSON from API with retry
# Usage: fetch_json_api <url> [max_retries]
fetch_json_api() {
    local url="$1"
    local max_retries="${2:-3}"
    local retry_count=0
    local result=""
    
    while (( retry_count < max_retries )); do
        if result=$(curl -fsSL "$url" 2>/dev/null); then
            echo "$result"
            return 0
        fi
        
        ((retry_count++))
        if (( retry_count < max_retries )); then
            sleep 2
        fi
    done
    
    msg_error "Échec récupération API après $max_retries tentatives: $url"
    return 1
}

# ==========================================================================
# VALIDATION FUNCTIONS
# ==========================================================================

# Validate IP address (IPv4)
# Usage: validate_ipv4 <ip>
validate_ipv4() {
    local ip="$1"
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! "$ip" =~ $ip_regex ]]; then
        return 1
    fi
    
    # Check each octet
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            return 1
        fi
    done
    
    return 0
}

# Validate port number
# Usage: validate_port <port>
validate_port() {
    local port="$1"
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if (( port < 1 || port > 65535 )); then
        return 1
    fi
    
    return 0
}

# Check if port is available
# Usage: is_port_available <port>
is_port_available() {
    local port="$1"
    
    if ! validate_port "$port"; then
        msg_error "Port invalide: $port"
        return 1
    fi
    
    if ss -tulnp | grep -q ":${port}\s"; then
        return 1
    fi
    
    return 0
}

# ==========================================================================
# SYSTEM CHECKS
# ==========================================================================

# Check if running in a container
# Usage: is_container
is_container() {
    [[ -f /.dockerenv ]] || grep -q 'lxc\|docker' /proc/1/cgroup 2>/dev/null
}

# Check available disk space
# Usage: check_disk_space <path> <min_mb>
check_disk_space() {
    local path="$1"
    local min_mb="$2"
    local available_mb
    
    available_mb=$(df -BM "$path" | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
    
    if (( available_mb < min_mb )); then
        msg_error "Espace disque insuffisant sur $path: ${available_mb}MB disponible, ${min_mb}MB requis"
        return 1
    fi
    
    return 0
}

# ==========================================================================
# BACKUP & ROLLBACK
# ==========================================================================

# Create timestamped backup of a file or directory
# Usage: create_backup <path>
create_backup() {
    local path="$1"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${path}.backup_${timestamp}"
    
    if [[ ! -e "$path" ]]; then
        msg_warn "Chemin inexistant, pas de backup: $path"
        return 0
    fi
    
    if cp -r "$path" "$backup_path" 2>/dev/null; then
        msg_ok "Backup créé: $backup_path"
        echo "$backup_path"
        return 0
    else
        msg_error "Échec création backup: $path"
        return 1
    fi
}

# Restore from backup
# Usage: restore_backup <backup_path> <original_path>
restore_backup() {
    local backup_path="$1"
    local original_path="$2"
    
    if [[ ! -e "$backup_path" ]]; then
        msg_error "Backup introuvable: $backup_path"
        return 1
    fi
    
    # Remove current version if exists
    rm -rf "$original_path"
    
    if mv "$backup_path" "$original_path"; then
        msg_ok "Restauration réussie: $original_path"
        return 0
    else
        msg_error "Échec restauration: $backup_path -> $original_path"
        return 1
    fi
}

# ==========================================================================
# SERVICE MANAGEMENT
# ==========================================================================

# Safely restart a service with health check
# Usage: restart_service_safely <service_name> [timeout]
restart_service_safely() {
    local service="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    msg_info "Redémarrage de $service..."
    
    if ! systemctl restart "$service"; then
        msg_error "Échec du redémarrage de $service"
        return 1
    fi
    
    # Wait for service to be active
    while (( elapsed < timeout )); do
        if systemctl is-active --quiet "$service"; then
            msg_ok "Service $service actif"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    msg_error "Timeout: $service n'est pas devenu actif après ${timeout}s"
    systemctl status "$service" --no-pager
    return 1
}

# ==========================================================================
# FILE OPERATIONS
# ==========================================================================

# Atomic file write (write to temp, then move)
# Usage: atomic_write <file_path> <content>
atomic_write() {
    local file_path="$1"
    local content="$2"
    local temp_file="${file_path}.tmp.$$"
    
    # Write to temp file
    if ! echo "$content" > "$temp_file"; then
        msg_error "Échec écriture fichier temporaire: $temp_file"
        rm -f "$temp_file"
        return 1
    fi
    
    # Atomic move
    if mv "$temp_file" "$file_path"; then
        return 0
    else
        msg_error "Échec déplacement atomique: $temp_file -> $file_path"
        rm -f "$temp_file"
        return 1
    fi
}

# Safe sed replacement (creates backup)
# Usage: safe_sed <file> <pattern> <replacement>
safe_sed() {
    local file="$1"
    local pattern="$2"
    local replacement="$3"
    local backup_suffix=".bak.$(date +%s)"
    
    if [[ ! -f "$file" ]]; then
        msg_error "Fichier inexistant: $file"
        return 1
    fi
    
    if sed -i"${backup_suffix}" "s|${pattern}|${replacement}|g" "$file"; then
        msg_ok "Modification appliquée: $file"
        return 0
    else
        msg_error "Échec modification sed: $file"
        [[ -f "${file}${backup_suffix}" ]] && mv "${file}${backup_suffix}" "$file"
        return 1
    fi
}

# ==========================================================================
# LOGGING HELPERS
# ==========================================================================

# Log with different levels
log_debug() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $*"
}

log_trace() {
    [[ "${TRACE:-}" == "1" ]] && log "TRACE: $*"
}

# ==========================================================================
# COMPATIBILITY CHECKS
# ==========================================================================

# Check if command exists and is executable
# Usage: require_command <command> [package_name]
require_command() {
    local cmd="$1"
    local pkg="${2:-$1}"
    
    if ! command -v "$cmd" &>/dev/null; then
        msg_error "Commande requise non trouvée: $cmd"
        msg_info "Installation recommandée: apt-get install -y $pkg"
        return 1
    fi
    
    return 0
}

# Check minimum version
# Usage: check_min_version <current> <minimum>
check_min_version() {
    local current="$1"
    local minimum="$2"
    
    if [[ "$(printf '%s\n' "$minimum" "$current" | sort -V | head -n1)" != "$minimum" ]]; then
        msg_error "Version insuffisante: $current < $minimum"
        return 1
    fi
    
    return 0
}

# ==========================================================================
# END OF COMMON LIBRARY
# ==========================================================================
