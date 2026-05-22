#!/usr/bin/env bash
# ==========================================================================
# Test Suite for AdGuard Home & Unbound Installer
# ==========================================================================
# Automated testing framework for validation and health checks
# Usage: ./tests/test_suite.sh [--test <test_name>] [--verbose]
# ==========================================================================

# Note: No set -e because we need tests to continue even if some fail

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Source shared library for actual function implementations
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR_TEST}/../lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR_TEST}/../lib/common.sh"
fi

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Test mode
VERBOSE=${VERBOSE:-0}
SPECIFIC_TEST=""

# ==========================================================================
# TEST FRAMEWORK
# ==========================================================================

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
    ((TESTS_TOTAL++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
    ((TESTS_TOTAL++))
}

skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"
    
    if [[ "$expected" == "$actual" ]]; then
        pass "$message"
    else
        fail "$message (expected: '$expected', got: '$actual')"
    fi
}

assert_true() {
    local condition="$1"
    local message="${2:-Assertion failed}"
    
    if [[ "$condition" == "true" || "$condition" == "0" ]]; then
        pass "$message"
    else
        fail "$message (condition was false)"
    fi
}

assert_command_exists() {
    local command="$1"
    local message="${2:-Command $command should exist}"
    
    if command -v "$command" &>/dev/null; then
        pass "$message"
    else
        fail "$message"
    fi
}

# ==========================================================================
# UNIT TESTS - VALIDATION FUNCTIONS
# ==========================================================================

test_validate_ipv4() {
    echo ""
    echo "=== Testing IPv4 Validation ==="
    
    # Uses validate_ipv4 from lib/common.sh
    
    # Valid IPs
    if validate_ipv4 "192.168.1.1" 2>/dev/null; then
        pass "Valid IP: 192.168.1.1"
    else
        fail "Valid IP: 192.168.1.1"
    fi
    
    if validate_ipv4 "10.0.0.1" 2>/dev/null; then
        pass "Valid IP: 10.0.0.1"
    else
        fail "Valid IP: 10.0.0.1"
    fi
    
    # Invalid IPs
    if ! validate_ipv4 "256.1.1.1" 2>/dev/null; then
        pass "Invalid IP: 256.1.1.1 (octet > 255)"
    else
        fail "Invalid IP: 256.1.1.1 should be rejected"
    fi
    
    if ! validate_ipv4 "192.168.1" 2>/dev/null; then
        pass "Invalid IP: 192.168.1 (incomplete)"
    else
        fail "Invalid IP: 192.168.1 should be rejected"
    fi
    
    if ! validate_ipv4 "abc.def.ghi.jkl" 2>/dev/null; then
        pass "Invalid IP: abc.def.ghi.jkl (non-numeric)"
    else
        fail "Invalid IP: abc.def.ghi.jkl should be rejected"
    fi
}

test_validate_port() {
    echo ""
    echo "=== Testing Port Validation ==="
    
    # Uses validate_port from lib/common.sh
    
    # Valid ports
    if validate_port "80"; then
        pass "Valid port: 80"
    else
        fail "Valid port: 80"
    fi
    
    if validate_port "53"; then
        pass "Valid port: 53"
    else
        fail "Valid port: 53"
    fi
    
    if validate_port "65535"; then
        pass "Valid port: 65535 (max)"
    else
        fail "Valid port: 65535"
    fi
    
    # Invalid ports
    if ! validate_port "0"; then
        pass "Invalid port: 0 (too low)"
    else
        fail "Invalid port: 0 should be rejected"
    fi
    
    if ! validate_port "65536"; then
        pass "Invalid port: 65536 (too high)"
    else
        fail "Invalid port: 65536 should be rejected"
    fi
    
    if ! validate_port "abc"; then
        pass "Invalid port: abc (non-numeric)"
    else
        fail "Invalid port: abc should be rejected"
    fi
}

# ==========================================================================
# INTEGRATION TESTS - SYSTEM CHECKS
# ==========================================================================

test_system_requirements() {
    echo ""
    echo "=== Testing System Requirements ==="
    
    # Check if running on Linux
    if [[ "$(uname -s)" == "Linux" ]]; then
        pass "Running on Linux"
    else
        skip "Not running on Linux (tests may be limited)"
    fi
    
    # Check required commands
    for cmd in bash awk sed grep; do
        assert_command_exists "$cmd" "Command exists: $cmd"
    done
    
    # Check if /proc/meminfo exists
    if [[ "$(uname -s)" != "Linux" ]]; then
        skip "System info /proc/meminfo is Linux-only"
    elif [[ -f /proc/meminfo ]]; then
        pass "System info available: /proc/meminfo"
    else
        fail "System info missing: /proc/meminfo"
    fi
}

test_disk_space_check() {
    echo ""
    echo "=== Testing Disk Space Check ==="

    if [[ "$(uname -s)" != "Linux" ]]; then
        skip "Disk space check uses Linux df -BM semantics"
        return 0
    fi
    
    # Uses check_disk_space from lib/common.sh
    
    # Should have at least 100MB free on /tmp
    if check_disk_space "/tmp" 100; then
        pass "Sufficient disk space on /tmp (>100MB)"
    else
        fail "Insufficient disk space on /tmp"
    fi
}

# ==========================================================================
# UNIT TESTS - DNS FUNCTIONS
# ==========================================================================

test_power_of_two() {
    echo ""
    echo "=== Testing Power of Two Calculation ==="
    
    assert_equals "1" "$(get_power_of_two 1)" "Power of 2 for 1"
    assert_equals "2" "$(get_power_of_two 2)" "Power of 2 for 2"
    assert_equals "2" "$(get_power_of_two 3)" "Power of 2 for 3"
    assert_equals "4" "$(get_power_of_two 4)" "Power of 2 for 4"
    assert_equals "4" "$(get_power_of_two 6)" "Power of 2 for 6"
    assert_equals "8" "$(get_power_of_two 8)" "Power of 2 for 8"
    assert_equals "8" "$(get_power_of_two 15)" "Power of 2 for 15"
}

# ==========================================================================
# FILE OPERATION TESTS
# ==========================================================================

test_atomic_write() {
    echo ""
    echo "=== Testing Atomic File Write ==="
    
    # Uses atomic_write from lib/common.sh
    
    local test_file="/tmp/test_atomic_$$"
    local test_content="Hello, World!"
    
    if atomic_write "$test_file" "$test_content"; then
        if [[ -f "$test_file" ]] && [[ "$(cat "$test_file")" == "$test_content" ]]; then
            pass "Atomic write successful"
        else
            fail "Atomic write: file content mismatch"
        fi
    else
        fail "Atomic write failed"
    fi
    
    rm -f "$test_file"
}

test_performance_defaults() {
    echo ""
    echo "=== Testing Performance Defaults ==="

    local script
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install_unbound_interactive.sh"

    if grep -q 'cache-min-ttl:' "$script" && grep -q 'serve-expired-client-timeout:' "$script"; then
        pass "Unbound low-latency cache tuning present"
    else
        fail "Unbound low-latency cache tuning missing"
    fi

    if grep -q -- '--benchmark' "$script"; then
        pass "Benchmark CLI option present"
    else
        fail "Benchmark CLI option missing"
    fi
}

test_power_of_two_edge() {
    echo ""
    echo "=== Testing Power of Two Edge Cases ==="
    
    assert_equals "1" "$(get_power_of_two 0)" "Power of 2 for 0"
    assert_equals "1" "$(get_power_of_two 1)" "Power of 2 for 1 (redundant)"
    assert_equals "1024" "$(get_power_of_two 2000)" "Power of 2 for 2000"
}

test_count_cpuset_cpus() {
    echo ""
    echo "=== Testing CPUSET CPU Counting ==="
    
    local result
    
    result=$(count_cpuset_cpus "0-3"); assert_equals "4" "$result" "Range 0-3"
    result=$(count_cpuset_cpus "0");    assert_equals "1" "$result" "Single CPU 0"
    result=$(count_cpuset_cpus "0,2,4"); assert_equals "3" "$result" "Multiple singles"
    result=$(count_cpuset_cpus "0-1,4-7"); assert_equals "6" "$result" "Mixed ranges"
    if result=$(count_cpuset_cpus ""); then
        fail "Empty cpuset should fail"
    else
        pass "Empty cpuset should fail"
    fi
}

test_performance_profile_boundaries() {
    echo ""
    echo "=== Testing Performance Profile Boundaries ==="

    local script
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install_unbound_interactive.sh"

    local rams=(512 1024 2048 4096)
    local prev_rrset=0 prev_jostle=0 prev_client_timeout=0
    local ram result rrset msg qpt outgoing jostle client_timeout reply_ttl

    for ram in "${rams[@]}"; do
        result=$(bash -c '
            source "$1"
            INTERACTIVE=false
            CPU_CORES=4
            RAM_MB="$2"
            _RESOURCES_CACHED=true
            calculate_optimized_settings
            echo "${RRSET_CACHE_SIZE}:${MSG_CACHE_SIZE}:${QUERIES_PER_THREAD}:${OUTGOING_RANGE}:${JOSTLE_TIMEOUT}:${SERVE_EXPIRED_CLIENT_TIMEOUT}:${SERVE_EXPIRED_REPLY_TTL}"
        ' _ "$script" "$ram" 2>/dev/null)

        if [[ -z "$result" ]]; then
            fail "Calcul tuning dynamique impossible pour ${ram}MB"
            continue
        fi

        rrset=${result%%:*}; result=${result#*:}
        msg=${result%%:*}; result=${result#*:}
        qpt=${result%%:*}; result=${result#*:}
        outgoing=${result%%:*}; result=${result#*:}
        jostle=${result%%:*}; result=${result#*:}
        client_timeout=${result%%:*}
        reply_ttl=${result##*:}

        rrset=${rrset%m}
        msg=${msg%m}

        if (( msg * 2 == rrset )); then
            pass "${ram}MB: ratio cache rrset/msg optimal (2:1)"
        else
            fail "${ram}MB: ratio cache invalide rrset=${rrset} msg=${msg}"
        fi

        if (( rrset >= prev_rrset )); then
            pass "${ram}MB: cache rrset non décroissant (${rrset}m)"
        else
            fail "${ram}MB: cache rrset décroissant (${rrset}m < ${prev_rrset}m)"
        fi

        if (( qpt >= 512 && qpt <= 2048 )); then
            pass "${ram}MB: num-queries-per-thread borné (${qpt})"
        else
            fail "${ram}MB: num-queries-per-thread hors bornes (${qpt})"
        fi

        if (( outgoing >= 512 && outgoing <= 4096 )); then
            pass "${ram}MB: outgoing-range borné (${outgoing})"
        else
            fail "${ram}MB: outgoing-range hors bornes (${outgoing})"
        fi

        if (( jostle >= 80 && jostle <= 500 )); then
            pass "${ram}MB: jostle-timeout borné (${jostle})"
        else
            fail "${ram}MB: jostle-timeout hors bornes (${jostle})"
        fi

        if (( client_timeout >= 1200 && client_timeout <= 2400 )); then
            pass "${ram}MB: serve-expired-client-timeout borné (${client_timeout})"
        else
            fail "${ram}MB: serve-expired-client-timeout hors bornes (${client_timeout})"
        fi

        if (( reply_ttl == 30 || reply_ttl == 60 || reply_ttl == 120 )); then
            pass "${ram}MB: serve-expired-reply-ttl valide (${reply_ttl})"
        else
            fail "${ram}MB: serve-expired-reply-ttl invalide (${reply_ttl})"
        fi

        if (( jostle >= prev_jostle )); then
            pass "${ram}MB: jostle-timeout non décroissant (${jostle})"
        else
            fail "${ram}MB: jostle-timeout décroissant (${jostle} < ${prev_jostle})"
        fi

        if (( client_timeout >= prev_client_timeout )); then
            pass "${ram}MB: serve-expired-client-timeout non décroissant (${client_timeout})"
        else
            fail "${ram}MB: serve-expired-client-timeout décroissant (${client_timeout} < ${prev_client_timeout})"
        fi

        prev_rrset=$rrset
        prev_jostle=$jostle
        prev_client_timeout=$client_timeout
    done
}

test_validate_ipv4_edge() {
    echo ""
    echo "=== Testing IPv4 Validation Edge Cases ==="
    
    # Uses validate_ipv4 from lib/common.sh
    
    if validate_ipv4 "0.0.0.0" 2>/dev/null; then
        pass "Valid IP: 0.0.0.0 (min)"
    else
        fail "Valid IP: 0.0.0.0 should be accepted"
    fi
    
    if validate_ipv4 "255.255.255.255" 2>/dev/null; then
        pass "Valid IP: 255.255.255.255 (max)"
    else
        fail "Valid IP: 255.255.255.255 should be accepted"
    fi
    
    if ! validate_ipv4 "" 2>/dev/null; then
        pass "Invalid IP: empty string"
    else
        fail "Invalid IP: empty string should be rejected"
    fi
    
    if validate_ipv4 "192.168.1.01" 2>/dev/null; then
        pass "IP with leading zeros: 192.168.1.01 (decimally valid)"
    else
        fail "IP with leading zeros: 192.168.1.01 should be accepted"
    fi
}

# ==========================================================================
# MAIN TEST RUNNER
# ==========================================================================

run_all_tests() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   AdGuard Home & Unbound Installer - Test Suite       ║"
    echo "╚════════════════════════════════════════════════════════╝"
    
    test_validate_ipv4
    test_validate_port
    test_system_requirements
    test_disk_space_check
    test_power_of_two
    test_atomic_write
    test_performance_defaults
    test_power_of_two_edge
    test_count_cpuset_cpus
    test_performance_profile_boundaries
    test_validate_ipv4_edge
    
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   Test Summary                                         ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "Total Tests:  $TESTS_TOTAL"
    echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
    echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
    echo ""
    
    if (( TESTS_FAILED == 0 )); then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        return 1
    fi
}

# ==========================================================================
# CLI ARGUMENT PARSING
# ==========================================================================

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
    --test <name>   Run specific test (e.g., --test validate_ipv4)
    --verbose       Show detailed output
    --help          Show this help message

Tests Available:
    - validate_ipv4
    - validate_port
    - system_requirements
    - disk_space_check
    - power_of_two
    - power_of_two_edge
    - count_cpuset_cpus
    - performance_profile_boundaries
    - validate_ipv4_edge
    - atomic_write
    - performance_defaults
    - all (default)

Examples:
    $0                           # Run all tests
    $0 --test validate_ipv4      # Run specific test
    $0 --verbose                 # Verbose mode

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            SPECIFIC_TEST="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Run tests
if [[ -n "$SPECIFIC_TEST" ]]; then
    case "$SPECIFIC_TEST" in
        validate_ipv4) test_validate_ipv4 ;;
        validate_port) test_validate_port ;;
        system_requirements) test_system_requirements ;;
        disk_space_check) test_disk_space_check ;;
        power_of_two) test_power_of_two ;;
        power_of_two_edge) test_power_of_two_edge ;;
        count_cpuset_cpus) test_count_cpuset_cpus ;;
        performance_profile_boundaries) test_performance_profile_boundaries ;;
        validate_ipv4_edge) test_validate_ipv4_edge ;;
        atomic_write) test_atomic_write ;;
        performance_defaults) test_performance_defaults ;;
        *)
            echo "Unknown test: $SPECIFIC_TEST"
            show_usage
            exit 1
            ;;
    esac
else
    run_all_tests
fi
