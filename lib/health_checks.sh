#!/usr/bin/env bash
# ==========================================================================
# Health Checks & Validation Functions
# ==========================================================================
# Post-installation verification and diagnostic utilities
# ==========================================================================

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

# ==========================================================================
# DNS RESOLUTION TESTS
# ==========================================================================

# Test DNS resolution through Unbound
# Usage: test_unbound_resolution
test_unbound_resolution() {
    local test_domain="google.com"
    local unbound_port="${UNBOUND_PORT:-5335}"
    
    msg_info "Test de résolution DNS via Unbound (port $unbound_port)..."
    
    if ! command -v dig &>/dev/null; then
        msg_warn "dig non disponible, installation de dnsutils..."
        apt-get install -y dnsutils &>/dev/null || return 1
    fi
    
    local result
    if result=$(dig @127.0.0.1 -p "$unbound_port" "$test_domain" +short +timeout=5 2>&1); then
        if [[ -n "$result" ]]; then
            msg_ok "Résolution DNS fonctionnelle: $test_domain -> $result"
            return 0
        else
            msg_error "Résolution vide pour $test_domain"
            return 1
        fi
    else
        msg_error "Échec résolution DNS: $result"
        return 1
    fi
}

# Test DNSSEC validation
# Usage: test_dnssec_validation
test_dnssec_validation() {
    local test_domain="dnssec-failed.org"
    local unbound_port="${UNBOUND_PORT:-5335}"
    
    msg_info "Test DNSSEC (doit échouer sur domaine invalide)..."
    
    # This domain has intentionally broken DNSSEC
    if dig @127.0.0.1 -p "$unbound_port" "$test_domain" +timeout=5 2>&1 | grep -q "SERVFAIL"; then
        msg_ok "DNSSEC fonctionne correctement (SERVFAIL attendu)"
        return 0
    else
        msg_warn "DNSSEC pourrait ne pas fonctionner comme prévu"
        return 1
    fi
}

# Test DoT connectivity
# Usage: test_dot_connectivity
test_dot_connectivity() {
    msg_info "Test connectivité DoT (DNS-over-TLS)..."
    
    # Test connection to Cloudflare DoT
    if timeout 5 openssl s_client -connect 1.1.1.1:853 </dev/null 2>&1 | grep -q "CONNECTED"; then
        msg_ok "Connectivité DoT fonctionnelle"
        return 0
    else
        msg_warn "Problème de connectivité DoT (firewall ?)"
        return 1
    fi
}

# ==========================================================================
# SERVICE HEALTH CHECKS
# ==========================================================================

# Comprehensive Unbound health check
# Usage: check_unbound_health
check_unbound_health() {
    local errors=0
    
    msg_info "Vérification santé Unbound..."
    
    # 1. Service status
    if ! systemctl is-active --quiet unbound; then
        msg_error "Service Unbound non actif"
        ((errors++))
    else
        msg_ok "Service Unbound actif"
    fi
    
    # 2. Config validity
    if ! unbound-checkconf &>/dev/null; then
        msg_error "Configuration Unbound invalide"
        unbound-checkconf 2>&1 | head -n 10
        ((errors++))
    else
        msg_ok "Configuration Unbound valide"
    fi
    
    # 3. Port listening
    if ! ss -tulnp | grep -q ":${UNBOUND_PORT:-5335}\s.*unbound"; then
        msg_error "Unbound n'écoute pas sur le port ${UNBOUND_PORT:-5335}"
        ((errors++))
    else
        msg_ok "Unbound écoute sur le port ${UNBOUND_PORT:-5335}"
    fi
    
    # 4. DNS resolution test
    if ! test_unbound_resolution; then
        ((errors++))
    fi
    
    # 5. Cache stats
    if command -v unbound-control &>/dev/null; then
        local cache_hits
        cache_hits=$(unbound-control stats_noreset 2>/dev/null | grep "total.num.cachehits" | awk '{print $2}')
        if [[ -n "$cache_hits" ]]; then
            msg_ok "Cache Unbound fonctionnel ($cache_hits hits)"
        fi
    fi
    
    return "$errors"
}

# Comprehensive AdGuard Home health check
# Usage: check_adguard_health
check_adguard_health() {
    local errors=0
    local agh_url="http://127.0.0.1:3000"
    
    msg_info "Vérification santé AdGuard Home..."
    
    # 1. Service status
    if ! systemctl is-active --quiet AdGuardHome; then
        msg_error "Service AdGuard Home non actif"
        ((errors++))
    else
        msg_ok "Service AdGuard Home actif"
    fi
    
    # 2. Config file exists
    if [[ ! -f "${AGH_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}" ]]; then
        msg_error "Fichier de configuration AdGuard introuvable"
        ((errors++))
    else
        msg_ok "Fichier de configuration AdGuard présent"
    fi
    
    # 3. Port 3000 listening
    if ! ss -tulnp | grep -q ":3000\s"; then
        msg_error "AdGuard Home n'écoute pas sur le port 3000"
        ((errors++))
    else
        msg_ok "AdGuard Home écoute sur le port 3000"
    fi
    
    # 4. Web UI reachable
    if command -v curl &>/dev/null; then
        if curl -fsSL --max-time 5 "$agh_url" &>/dev/null; then
            msg_ok "Interface web AdGuard accessible"
        else
            msg_warn "Interface web AdGuard non accessible (première installation ?)"
        fi
    fi
    
    # 5. Upstream configuration
    if [[ -f "${AGH_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}" ]]; then
        if grep -q "127.0.0.1:${UNBOUND_PORT:-5335}" "${AGH_YAML}"; then
            msg_ok "AdGuard utilise bien Unbound comme upstream"
        else
            msg_warn "AdGuard n'utilise peut-être pas Unbound"
            ((errors++))
        fi
    fi
    
    return "$errors"
}

# ==========================================================================
# PERFORMANCE DIAGNOSTICS
# ==========================================================================

# Generate performance report
# Usage: generate_performance_report
generate_performance_report() {
    local report_file="/tmp/dns_performance_report_$(date +%s).txt"
    
    cat > "$report_file" <<EOF
=================================================================
DNS Performance Report - $(date)
=================================================================

--- SYSTEM RESOURCES ---
CPU Cores: $(nproc --all)
RAM Total: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)
RAM Available: $(awk '/MemAvailable/ {printf "%.0f MB", $2/1024}' /proc/meminfo)

--- UNBOUND CONFIG ---
EOF
    
    if [[ -f /etc/unbound/unbound.conf ]]; then
        echo "Threads: $(grep -E '^\s*num-threads:' /etc/unbound/unbound.conf | awk '{print $2}')" >> "$report_file"
        echo "Cache Slabs: $(grep -E '^\s*msg-cache-slabs:' /etc/unbound/unbound.conf | awk '{print $2}')" >> "$report_file"
        echo "RRset Cache: $(grep -E '^\s*rrset-cache-size:' /etc/unbound/unbound.conf | awk '{print $2}')" >> "$report_file"
        echo "Msg Cache: $(grep -E '^\s*msg-cache-size:' /etc/unbound/unbound.conf | awk '{print $2}')" >> "$report_file"
    fi
    
    cat >> "$report_file" <<EOF

--- UNBOUND STATS ---
EOF
    
    if command -v unbound-control &>/dev/null; then
        unbound-control stats_noreset 2>/dev/null >> "$report_file" || echo "Stats non disponibles" >> "$report_file"
    fi
    
    cat >> "$report_file" <<EOF

--- NETWORK STATE ---
DNS Ports:
EOF
    
    ss -tulnp | grep -E ':(53|5335|3000)\s' >> "$report_file"
    
    msg_ok "Rapport généré: $report_file"
    echo "$report_file"
}

# Quick performance test (1000 queries)
# Usage: benchmark_dns_performance [num_queries]
benchmark_dns_performance() {
    local num_queries="${1:-1000}"
    local test_domains=("google.com" "github.com" "cloudflare.com" "amazon.com" "facebook.com")
    local unbound_port="${UNBOUND_PORT:-5335}"
    local concurrency="${DNS_BENCH_CONCURRENCY:-16}"
    
    msg_info "Benchmark DNS ($num_queries requêtes, concurrence $concurrency)..."
    
    if ! command -v dig &>/dev/null; then
        msg_error "dig requis pour le benchmark"
        return 1
    fi
    
    local start_time
    start_time=$(date +%s%N)
    
    for ((i=0; i<num_queries; i++)); do
        local domain="${test_domains[$((i % ${#test_domains[@]}))]}"
        dig @127.0.0.1 -p "$unbound_port" "$domain" +short +tries=1 +timeout=2 &>/dev/null &
        if (( (i + 1) % concurrency == 0 )); then
            wait
        fi
    done
    wait
    
    local end_time
    end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
    (( elapsed_ms < 1 )) && elapsed_ms=1
    local qps=$(( num_queries * 1000 / elapsed_ms ))
    local avg_ms=$(( elapsed_ms / num_queries ))
    
    msg_ok "Benchmark: ${num_queries} requêtes en ${elapsed_ms}ms (${qps} qps, moyenne ~${avg_ms}ms/requête)"
}

# ==========================================================================
# AUTOMATED FULL HEALTH CHECK
# ==========================================================================

# Run all health checks
# Usage: run_full_health_check
run_full_health_check() {
    local total_errors=0
    
    echo ""
    echo "=========================================="
    echo "  HEALTH CHECK COMPLET"
    echo "=========================================="
    echo ""
    
    # Unbound
    if ! check_unbound_health; then
        total_errors=$((total_errors + $?))
    fi
    
    echo ""
    
    # AdGuard Home
    if ! check_adguard_health; then
        total_errors=$((total_errors + $?))
    fi
    
    echo ""
    
    # DNSSEC
    test_dnssec_validation || true
    
    echo ""
    
    # DoT
    test_dot_connectivity || true
    
    echo ""
    echo "=========================================="
    if (( total_errors == 0 )); then
        msg_ok "✓ Tous les tests passés avec succès"
        return 0
    else
        msg_error "✗ $total_errors erreur(s) détectée(s)"
        return 1
    fi
}

# ==========================================================================
# END OF HEALTH CHECK LIBRARY
# ==========================================================================
