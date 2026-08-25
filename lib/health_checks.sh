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
        msg_warn "dig non disponible, installation de bind-tools..."
        apk add --no-cache bind-tools &>/dev/null || return 1
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
    if echo | openssl s_client -connect 1.1.1.1:853 2>/dev/null | grep -q "CONNECTED"; then
        msg_ok "Connectivité DoT fonctionnelle"
        return 0
    elif timeout 5 openssl s_client -connect 1.1.1.1:853 </dev/null 2>&1 | grep -q "CONNECTED"; then
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

    if [[ -f "$yaml" ]] && command -v python3 &>/dev/null; then
        port=$(python3 -c "
import yaml
try:
    with open('$yaml') as f:
        d = yaml.safe_load(f) or {}
    addr = d.get('http', {}).get('address', '')
    if ':' in str(addr):
        print(str(addr).split(':')[-1])
    elif addr:
        print(addr)
    elif 'bind_port' in d:
        print(d['bind_port'])
except Exception:
    pass
" 2>/dev/null)
    fi

    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    if [[ -f "$yaml" ]]; then
        port=$(awk '
            /^[[:space:]]*address:[[:space:]]*/ {
                line = $0
                sub(/^[^:]+:[[:space:]]*/, "", line)
                gsub(/[\"[:space:]]/, "", line)
                if (line ~ /:[0-9]+$/) { sub(/^.*:/, "", line); print line; exit }
                if (line ~ /^[0-9]+$/) { print line; exit }
            }
            /^[[:space:]]*bind_port:[[:space:]]*[0-9]+/ { print $2; exit }
        ' "$yaml" 2>/dev/null)
    fi

    echo "${port:-3000}"
}

is_port_listening() {
    local port="$1"
    if command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -qE "(:|[[:space:]])${port}([[:space:]]|$)"; then
            return 0
        fi
    fi
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -qE "(:|[[:space:]])${port}([[:space:]]|$)"; then
            return 0
        fi
    fi
    if command -v nc &>/dev/null; then
        if nc -z 127.0.0.1 "$port" &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

is_adguard_web_reachable() {
    local port="$1"
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null)
    if [[ "$code" =~ ^[234] ]]; then
        return 0
    fi
    code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "https://127.0.0.1:${port}/" 2>/dev/null)
    if [[ "$code" =~ ^[234] ]]; then
        return 0
    fi
    return 1
}

# Comprehensive Unbound health check
# Usage: check_unbound_health
check_unbound_health() {
    local errors=0

    msg_info "Vérification santé Unbound..."

    # 1. Service status
    if ! rc-service unbound status &>/dev/null && ! pgrep -f "unbound" &>/dev/null; then
        msg_error "Service Unbound non actif"
        ((++errors))
    else
        msg_ok "Service Unbound actif"
    fi

    # 2. Config validity
    local checkconf_output=""
    local checkconf_ok=false
    if checkconf_output=$(unbound-checkconf 2>&1); then
        checkconf_ok=true
    elif checkconf_output=$(unbound-checkconf /etc/unbound/unbound.conf 2>&1); then
        checkconf_ok=true
    fi

    if [[ "$checkconf_ok" != "true" ]]; then
        msg_error "Configuration Unbound invalide"
        printf '%s\n' "$checkconf_output" | head -n 10
        ((++errors))
    else
        msg_ok "Configuration Unbound valide"
    fi

    # 3. Port listening
    if ! is_port_listening "${UNBOUND_PORT:-5335}"; then
        msg_error "Unbound n'écoute pas sur le port ${UNBOUND_PORT:-5335}"
        ((++errors))
    else
        msg_ok "Unbound écoute sur le port ${UNBOUND_PORT:-5335}"
    fi

    # 4. DNS resolution test
    if ! test_unbound_resolution; then
        ((++errors))
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
    local service_active=false
    if rc-service AdGuardHome status &>/dev/null \
        || rc-service adguardhome status &>/dev/null \
        || pgrep -f "AdGuardHome" &>/dev/null; then
        service_active=true
    fi

    if [[ "$service_active" != "true" ]]; then
        msg_error "Service AdGuard Home non actif"
        ((++errors))
    else
        msg_ok "Service AdGuard Home actif"
    fi

    # 2. Config file exists
    if [[ ! -f "${AGH_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}" ]]; then
        msg_error "Fichier de configuration AdGuard introuvable"
        ((++errors))
    else
        msg_ok "Fichier de configuration AdGuard présent"
    fi

    # Detect actual active web port (80 or 3000 or config value)
    if ! is_port_listening "$agh_port"; then
        if is_port_listening 80; then
            agh_port=80
        elif is_port_listening 3000; then
            agh_port=3000
        fi
    fi

    # 3. Web port listening
    if ! is_port_listening "$agh_port"; then
        msg_error "AdGuard Home n'écoute pas sur le port ${agh_port}"
        ((++errors))
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
            ((++errors))
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

    local UNBOUND_CONF_NEW="/etc/unbound/unbound.conf.d/99-adguard-unbound-installer.conf"
    if [[ -f "$UNBOUND_CONF_NEW" ]]; then
        awk 'BEGIN {
            v["num-threads"]="Threads"; v["msg-cache-slabs"]="Cache Slabs"
            v["rrset-cache-size"]="RRset Cache"; v["msg-cache-size"]="Msg Cache"
            v["key-cache-size"]="Key Cache"
        }
        /^\s*(num-threads|msg-cache-slabs|rrset-cache-size|msg-cache-size|key-cache-size):/ {
            print v[$1]": "$2
        }' "$UNBOUND_CONF_NEW" >> "$report_file"
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
            ((++fails))
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
    local ub_rc=0
    check_unbound_health || ub_rc=$?
    if (( ub_rc != 0 )); then
        total_errors=$((total_errors + ub_rc))
    fi

    echo ""

    # AdGuard Home
    local agh_rc=0
    check_adguard_health || agh_rc=$?
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
# DNS BENCHMARK AVEC DNSPERF (REALISTE)
# ==========================================================================

# Génère un queryfile pour dnsperf à partir de domaines communs
# Usage: generate_dnsperf_queryfile <output_path> [num_queries]
generate_dnsperf_queryfile() {
    local output="${1:-/tmp/dnsperf_queries.txt}"
    local num="${2:-10000}"
    local domains=(
        "google.com A"
        "google.com AAAA"
        "www.google.com A"
        "cloudflare.com A"
        "github.com A"
        "api.github.com A"
        "facebook.com A"
        "microsoft.com A"
        "apple.com A"
        "amazon.com A"
        "aws.amazon.com A"
        "netflix.com A"
        "youtube.com A"
        "reddit.com A"
        "stackoverflow.com A"
        "wikipedia.org A"
        "kernel.org A"
        "python.org A"
        "docker.com A"
        "hub.docker.com A"
        "npmjs.com A"
        "debian.org A"
        "ubuntu.com A"
        "archlinux.org A"
        "gnu.org A"
        "gitlab.com A"
        "bitbucket.org A"
        "linkedin.com A"
        "twitter.com A"
        "x.com A"
        "zoom.us A"
        "office.com A"
        "login.microsoftonline.com A"
        "icloud.com A"
        "cdn.sstatic.net A"
        "1.1.1.1 A"
        "one.one.one.one A"
        "dns.google A"
        "dns.quad9.net A"
        "unbound.docs.nlnetlabs.nl A"
        "adguard.com A"
        "raw.githubusercontent.com A"
        "pypi.org A"
        "registry.npmjs.org A"
        "nginx.org A"
        "apache.org A"
        "mysql.com A"
        "postgresql.org A"
        "git-scm.com A"
        "nodejs.org A"
    )
    local num_domains=${#domains[@]}
    local blocks=$(( num / num_domains ))
    local rem=$(( num % num_domains ))
    local i r
    true > "$output"
    # Écriture par blocs (un seul open/écrit par bloc) au lieu d'une
    # ouverture/écriture par ligne — divise l'I/O par ~num_domains.
    for ((r=0; r<blocks; r++)); do
        printf '%s\n' "${domains[@]}" >> "$output"
    done
    if (( rem > 0 )); then
        for ((i=0; i<rem; i++)); do
            printf '%s\n' "${domains[i]}" >> "$output"
        done
    fi
    msg_ok "Queryfile généré: ${num} requêtes, ${num_domains} domaines uniques"
}

# Installe dnsperf si nécessaire
# Usage: ensure_dnsperf
ensure_dnsperf() {
    if command -v dnsperf &>/dev/null; then
        return 0
    fi
    msg_info "Installation de dnsperf..."
    apk update -q &>/dev/null || true
    apk add --no-cache dnsperf 2>/dev/null && return 0
    # Fallback: compilation depuis source
    msg_info "dnsperf non disponible via apk, tentative compilation..."
    apk add --no-cache build-base autoconf automake libtool openssl-dev ldns-dev git &>/dev/null || true
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if git clone --depth 1 https://github.com/DNS-OARC/dnsperf.git "$tmp_dir/dnsperf" 2>/dev/null; then
        (cd "$tmp_dir/dnsperf" && autoreconf -fi && ./configure --quiet && make -j"$(nproc)" --quiet && make install --quiet) 2>/dev/null || {
            msg_warn "Échec compilation dnsperf, fallback dig benchmark"
            rm -rf "$tmp_dir"
            return 1
        }
        rm -rf "$tmp_dir"
        msg_ok "dnsperf compilé avec succès"
        return 0
    fi
    rm -rf "$tmp_dir"
    msg_warn "dnsperf indisponible, fallback benchmark basique"
    return 1
}

# Benchmark DNS réaliste avec dnsperf
# Usage: benchmark_dnsperf [num_queries] [output_prefix]
benchmark_dnsperf() {
    local num_queries="${1:-10000}"
    local prefix="${2:-/tmp/dnsperf}"
    local unbound_port="${UNBOUND_PORT:-5335}"
    local queryfile="${prefix}_queries.txt"
    local report="${prefix}_report.txt"

    msg_info "Benchmark DNS réaliste (dnsperf, ${num_queries} requêtes)..."
    ensure_dnsperf || {
        benchmark_dns_performance "$(( num_queries / 10 ))"
        return $?
    }

    generate_dnsperf_queryfile "$queryfile" "$num_queries"

    if [[ ! -f "$queryfile" || ! -s "$queryfile" ]]; then
        msg_error "Queryfile invalide"
        return 1
    fi

    # Warm-up: 500 requêtes
    msg_info "Warm-up (500 requêtes)..."
    dnsperf -s 127.0.0.1 -p "$unbound_port" -d /dev/null -l 3 -q 500 >/dev/null 2>&1 || true

    # Benchmark réel
    msg_info "Exécution du benchmark..."
    dnsperf -s 127.0.0.1 -p "$unbound_port" \
        -d "$queryfile" \
        -l 30 \
        -c 10 \
        -q "$num_queries" \
        -T 5 \
        -S 1 \
        -v 2>&1 | tee "$report" || true

    # Extraction des metrics clés
    local qps avg_latency p50 p95 p99 lost
    if [[ -f "$report" ]]; then
        qps=$(grep -oP 'Queries per second:\s+\K[\d.]+' "$report" || echo "N/A")
        avg_latency=$(grep -oP 'Average latency:\s+\K[\d.]+' "$report" || echo "N/A")
        p50=$(grep -oP '50th percentile:\s+\K[\d.]+' "$report" || echo "N/A")
        p95=$(grep -oP '95th percentile:\s+\K[\d.]+' "$report" || echo "N/A")
        p99=$(grep -oP '99th percentile:\s+\K[\d.]+' "$report" || echo "N/A")
        lost=$(grep -oP 'Lost queries:\s+\K[\d.]+' "$report" || echo "N/A")
        msg_ok "Benchmark dnsperf terminé"
        echo ""
        echo "=========================================="
        echo "  RÉSULTATS BENCHMARK DNS"
        echo "=========================================="
        echo "  QPS:           ${qps}"
        echo "  Latence avg:   ${avg_latency} ms"
        echo "  P50:           ${p50} ms"
        echo "  P95:           ${p95} ms"
        echo "  P99:           ${p99} ms"
        echo "  Perte:         ${lost}%"
        echo "=========================================="
    else
        msg_warn "Rapport de benchmark non trouvé"
    fi

    rm -f "$queryfile"
    echo "Rapport détaillé: $report"
}

# Benchmark comparatif avant/après tuning
# Usage: benchmark_comparative <before_label> <after_label>
benchmark_comparative() {
    local before_label="${1:-avant}"
    local after_label="${2:-après}"
    local tmp_before="/tmp/bench_before.txt"
    local tmp_after="/tmp/bench_after.txt"
    local report="/tmp/bench_comparative.txt"

    msg_info "Benchmark comparatif: ${before_label} → ${after_label}"

    benchmark_dnsperf 5000 "${tmp_before%.txt}" 2>&1 | tail -5
    mv "$report" "$tmp_before" 2>/dev/null || true

    msg_info "Benchmark ${after_label}..."
    benchmark_dnsperf 5000 "${tmp_after%.txt}" 2>&1 | tail -5
    mv "$report" "$tmp_after" 2>/dev/null || true

    # Génération rapport comparatif
    {
        echo "=================================================="
        echo "BENCHMARK COMPARATIF DNS"
        echo "${before_label} → ${after_label}"
        echo "Date: $(date)"
        echo "=================================================="
        echo ""
        if [[ -f "$tmp_before" && -f "$tmp_after" ]]; then
            echo "--- ${before_label} ---"
            grep -E '(Queries per second|Average latency|percentile|Lost)' "$tmp_before"
            echo ""
            echo "--- ${after_label} ---"
            grep -E '(Queries per second|Average latency|percentile|Lost)' "$tmp_after"

            local qps_before qps_after
            qps_before=$(grep -oP 'Queries per second:\s+\K[\d.]+' "$tmp_before" || echo 0)
            qps_after=$(grep -oP 'Queries per second:\s+\K[\d.]+' "$tmp_after" || echo 0)
            local p95_before p95_after
            p95_before=$(grep -oP '95th percentile:\s+\K[\d.]+' "$tmp_before" || echo 0)
            p95_after=$(grep -oP '95th percentile:\s+\K[\d.]+' "$tmp_after" || echo 0)

            if (( $(echo "$qps_before > 0" | bc -l 2>/dev/null || echo 0) )); then
                local qps_gain
                qps_gain=$(echo "scale=2; (${qps_after} - ${qps_before}) / ${qps_before} * 100" | bc -l 2>/dev/null || echo "N/A")
                echo ""
                echo "GAINS:"
                echo "  QPS:  ${qps_before} → ${qps_after} (${qps_gain}%)"
                if (( $(echo "$p95_after > 0" | bc -l 2>/dev/null || echo 0) )); then
                    local p95_gain
                    p95_gain=$(echo "scale=2; (${p95_before} - ${p95_after}) / ${p95_before} * 100" | bc -l 2>/dev/null || echo "N/A")
                    echo "  P95:  ${p95_before}ms → ${p95_after}ms (${p95_gain}%)"
                fi
            fi
        fi
    } > "$report"
    rm -f "$tmp_before" "$tmp_after"

    msg_ok "Rapport comparatif: $report"
    cat "$report"
}

# ==========================================================================
# END OF HEALTH CHECK LIBRARY
# ==========================================================================
