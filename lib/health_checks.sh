#!/usr/bin/env bash
# ==========================================================================
# Health Checks & Validation Functions
# ==========================================================================
# Post-installation verification and diagnostic utilities
# ==========================================================================

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/common.sh"
fi

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

get_adguard_web_port() {
    local yaml="${AGH_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}"
    local port="${AGH_WEB_PORT:-}"

    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    if [[ -f "$yaml" ]]; then
        port=$(awk '
            /^[[:space:]]*bind_port:[[:space:]]*[0-9]+/ { print $2; exit }
            /^[[:space:]]*address:[[:space:]]*/ {
                line = $0
                sub(/^[^:]+:[[:space:]]*/, "", line)
                gsub(/[\"[:space:]]/, "", line)
                if (line ~ /:[0-9]+$/) { sub(/^.*:/, "", line); print line; exit }
                if (line ~ /^[0-9]+$/) { print line; exit }
            }
        ' "$yaml" 2>/dev/null)
    fi

    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
    else
        echo "3000"
    fi
}

is_port_listening() {
    local port="$1"
    ss -H -tuln 2>/dev/null | awk -v port=":${port}" '$5 ~ port "$" { found = 1 } END { exit !found }'
}

is_adguard_web_reachable() {
    local port="$1"
    curl -kfsSL --max-time 5 "http://127.0.0.1:${port}" &>/dev/null \
        || curl -kfsSL --max-time 5 "https://127.0.0.1:${port}" &>/dev/null
}

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
    local checkconf_output=""
    local checkconf_ok=false
    if checkconf_output=$(unbound-checkconf 2>&1); then
        checkconf_ok=true
    elif grep -qiE 'trust anchor|auto-trust-anchor|root\.key' <<< "$checkconf_output" && command -v repair_unbound_trust_anchor &>/dev/null; then
        msg_warn "Trust anchor DNSSEC corrompue, tentative de réparation..."
        repair_unbound_trust_anchor || true
        if checkconf_output=$(unbound-checkconf 2>&1); then
            checkconf_ok=true
        fi
    fi

    if [[ "$checkconf_ok" != "true" ]]; then
        msg_error "Configuration Unbound invalide"
        printf '%s\n' "$checkconf_output" | head -n 10
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
        cache_hits=$(unbound-control stats_noreset 2>/dev/null | awk '/total.num.cachehits/ {print $2}')
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
    local agh_port
    agh_port=$(get_adguard_web_port)

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
    
    # 3. Web port listening
    if ! is_port_listening "$agh_port"; then
        msg_error "AdGuard Home n'écoute pas sur le port ${agh_port}"
        ((errors++))
    else
        msg_ok "AdGuard Home écoute sur le port ${agh_port}"
    fi

    # 4. Web UI reachable
    if command -v curl &>/dev/null; then
        if is_adguard_web_reachable "$agh_port"; then
            msg_ok "Interface web AdGuard accessible sur le port ${agh_port}"
        else
            msg_warn "Interface web AdGuard non accessible sur le port ${agh_port} (première installation ?)"
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
    local report_file
    report_file="/tmp/dns_performance_report_$(date +%s).txt"
    local agh_port
    agh_port=$(get_adguard_web_port)
    
    local meminfo
    meminfo=$(awk '/MemTotal|MemAvailable/ {printf "%.0f ", $2/1024}' /proc/meminfo)
    local mem_total=${meminfo%% *}
    local mem_avail=${meminfo##* }

    cat > "$report_file" <<EOF
=================================================================
DNS Performance Report - $(date)
=================================================================

--- SYSTEM RESOURCES ---
CPU Cores: $(nproc --all)
RAM Total: ${mem_total} MB
RAM Available: ${mem_avail} MB

--- UNBOUND CONFIG ---
EOF
    
    if [[ -f /etc/unbound/unbound.conf ]]; then
        awk 'BEGIN {
            v["num-threads"]="Threads"; v["msg-cache-slabs"]="Cache Slabs"
            v["rrset-cache-size"]="RRset Cache"; v["msg-cache-size"]="Msg Cache"
            v["key-cache-size"]="Key Cache"
        }
        /^\s*(num-threads|msg-cache-slabs|rrset-cache-size|msg-cache-size|key-cache-size):/ {
            print v[$1]": "$2
        }' /etc/unbound/unbound.conf >> "$report_file"
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
    
    ss -tulnp | grep -E ":(53|5335|${agh_port})\\s" >> "$report_file" || true

    msg_ok "Rapport généré: $report_file"
    echo "$report_file"
}

# Quick performance test (300 queries)
# Usage: benchmark_dns_performance [num_queries]
benchmark_dns_performance() {
    local num_queries="${1:-300}"
    local unbound_port="${UNBOUND_PORT:-5335}"
    [[ "$num_queries" =~ ^[0-9]+$ ]] || num_queries=300
    (( num_queries < 10 )) && num_queries=10

    msg_info "Benchmark DNS ($num_queries requêtes)..."
    if ! command -v dig &>/dev/null; then
        msg_error "dig requis pour le benchmark"
        return 1
    fi

    local domains=(
        google.com github.com cloudflare.com amazon.com facebook.com
        microsoft.com apple.com netflix.com twitter.com linkedin.com
        wikipedia.org kernel.org python.org apache.org mozilla.org
        stackoverflow.net
    )
    local num_domains=${#domains[@]}
    local results_file
    results_file=$(mktemp)
    local fails=0

    # Warm-up cache
    local i
    for ((i=0; i<50; i++)); do
        dig @127.0.0.1 -p "$unbound_port" "${domains[$((i % num_domains))]}" +short +tries=1 +timeout=2 &>/dev/null
    done

    local start_time
    start_time=$(date +%s%N)

    for ((i=0; i<num_queries; i++)); do
        local tstart
        tstart=$(date +%s%N)
        if dig @127.0.0.1 -p "$unbound_port" "${domains[$((i % num_domains))]}" +short +tries=1 +timeout=2 &>/dev/null; then
            local elapsed=$(( ($(date +%s%N) - tstart) / 1000000 ))
            echo "$elapsed" >> "$results_file"
        else
            ((fails++))
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
    (( elapsed_ms < 1 )) && elapsed_ms=1
    local qps=$(( num_queries * 1000 / elapsed_ms ))

    local -a times=()
    local total_ms=0 t
    while read -r t; do
        times+=("$t")
        total_ms=$((total_ms + t))
    done < "$results_file"
    rm -f "$results_file"

    local count=${#times[@]}
    local avg_ms=0 p50=0 p95=0 p99=0
    if (( count > 0 )); then
        avg_ms=$((total_ms / count))
        local sorted
        sorted=$(printf '%s\n' "${times[@]}" | sort -n)
        local -a sorted_times
        mapfile -t sorted_times <<< "$sorted"
        p50=${sorted_times[$((count * 50 / 100))]}
        p95=${sorted_times[$((count * 95 / 100))]}
        p99=${sorted_times[$((count * 99 / 100))]}
    fi

    msg_ok "Benchmark: ${num_queries} requêtes en ${elapsed_ms}ms (${qps} qps, moyenne ${avg_ms}ms, P50=${p50}ms P95=${p95}ms P99=${p99}ms, échecs=${fails}/${num_queries})"
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
    check_unbound_health; local ub_rc=$?
    if (( ub_rc != 0 )); then
        total_errors=$((total_errors + ub_rc))
    fi
    
    echo ""
    
    # AdGuard Home
    check_adguard_health; local agh_rc=$?
    if (( agh_rc != 0 )); then
        total_errors=$((total_errors + agh_rc))
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
