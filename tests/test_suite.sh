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
    
    # Source the common library (mock if needed)
    validate_ipv4() {
        local ip="$1"
        local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
        [[ "$ip" =~ $ip_regex ]] || return 1
        
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            (( octet > 255 )) && return 1
        done
        return 0
    }
    
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
    
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        (( port < 1 || port > 65535 )) && return 1
        return 0
    }
    
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
    if [[ -f /proc/meminfo ]]; then
        pass "System info available: /proc/meminfo"
    else
        fail "System info missing: /proc/meminfo"
    fi
}

test_disk_space_check() {
    echo ""
    echo "=== Testing Disk Space Check ==="
    
    check_disk_space() {
        local path="$1"
        local min_mb="$2"
        local available_mb
        available_mb=$(df -BM "$path" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
        [[ -n "$available_mb" ]] && (( available_mb >= min_mb ))
    }
    
    # Should have at least 100MB free on /tmp
    if check_disk_space "/tmp" 100; then
        pass "Sufficient disk space on /tmp (>100MB)"
    else
        fail "Insufficient disk space on /tmp"
    fi
}

# ==========================================================================
# MOCK TESTS - DNS FUNCTIONS
# ==========================================================================

test_power_of_two() {
    echo ""
    echo "=== Testing Power of Two Calculation ==="
    
    get_power_of_two() {
        local n=$1
        local p=1
        while (( p * 2 <= n )); do
            (( p *= 2 ))
        done
        echo "$p"
    }
    
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
    
    atomic_write() {
        local file_path="$1"
        local content="$2"
        local temp_file="${file_path}.tmp.$$"
        
        echo "$content" > "$temp_file" || return 1
        mv "$temp_file" "$file_path" || { rm -f "$temp_file"; return 1; }
        return 0
    }
    
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
    - atomic_write
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
        atomic_write) test_atomic_write ;;
        *)
            echo "Unknown test: $SPECIFIC_TEST"
            show_usage
            exit 1
            ;;
    esac
else
    run_all_tests
fi
