#!/usr/bin/env bash
# Test: check-services.sh detects crashed services and restarts them
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-services.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-services-test.XXXXXX)
export SENTINEL_STATE="$TEST_TMPDIR/state"
export SENTINEL_LOGS="$TEST_TMPDIR/logs"
export SENTINEL_CONFIG="$TEST_TMPDIR/config"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

# Source utils (sets up logging, cooldowns, etc.)
source "$REPO_DIR/scripts/sentinel-utils.sh"

# Source config (sets thresholds)
source "$REPO_DIR/config/sentinel.conf"

# Track restarts and notifications via files (subshell-safe)
RESTART_LOG="$TEST_TMPDIR/restart.log"
NOTIFY_LOG="$TEST_TMPDIR/notify.log"
: > "$RESTART_LOG"
: > "$NOTIFY_LOG"

# =============================================================================
# MOCK FUNCTIONS
# =============================================================================
MOCK_LAUNCHCTL_OUTPUT=""
launchctl() {
    if [[ "$1" == "list" ]]; then
        echo "$MOCK_LAUNCHCTL_OUTPUT"
    elif [[ "$1" == "kickstart" ]]; then
        echo "$3" >> "$RESTART_LOG"
    fi
}

sentinel_notify() {
    echo "$1: $2" >> "$NOTIFY_LOG"
}

# Override for testing
MONITORED_SERVICES="com.test.service1,com.test.service2"
AUTO_RESTART=true
MAX_RESTARTS_PER_HOUR=3
PHASE1_CRITICAL=false

# Source the module under test
source "$REPO_DIR/scripts/lib/check-services.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    MOCK_LAUNCHCTL_OUTPUT=""
    : > "$RESTART_LOG"
    : > "$NOTIFY_LOG"
    PHASE1_CRITICAL=false
    AUTO_RESTART=true
    MONITORED_SERVICES="com.test.service1,com.test.service2"
    MAX_RESTARTS_PER_HOUR=3
    rm -f "$SENTINEL_STATE"/restart-*
    : > "$SENTINEL_LOGS/sentinel.log"
}

# --- Test 1: All services running ---
echo ""
echo "  --- Test: all services running ---"
reset_test_state
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1
5678	0	com.test.service2"

result=0
check_services || result=$?
assert_eq "0" "$result" "all running returns 0"

restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "0" "$restart_count" "no restarts when all running"

# --- Test 2: One service crashed ---
echo ""
echo "  --- Test: one service crashed ---"
reset_test_state
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1
-	1	com.test.service2"

result=0
check_services || result=$?
assert_eq "1" "$result" "crashed service returns 1"

restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "1" "$restart_count" "one service restarted"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "Restarted com.test.service2" "notification mentions restarted service"

# --- Test 3: Pressure gate blocks restarts ---
echo ""
echo "  --- Test: pressure gate blocks restarts ---"
reset_test_state
PHASE1_CRITICAL=true
MOCK_LAUNCHCTL_OUTPUT="-	1	com.test.service1
-	1	com.test.service2"

result=0
check_services || result=$?
restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "0" "$restart_count" "no restarts during pressure gate"

# --- Test 4: Crash loop detection ---
echo ""
echo "  --- Test: crash loop detection ---"
reset_test_state
MONITORED_SERVICES="com.test.service1"
MOCK_LAUNCHCTL_OUTPUT="-	1	com.test.service1"

# Simulate 3 recent restarts (already at limit)
now=$(date +%s)
{
    echo "$now"
    echo "$now"
    echo "$now"
} > "$SENTINEL_STATE/restart-com.test.service1"

result=0
check_services || result=$?
assert_eq "2" "$result" "crash loop returns 2"

restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "0" "$restart_count" "no restart when crash-looping"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "crash-looping" "notification mentions crash loop"

# --- Test 5: Auto-restart disabled ---
echo ""
echo "  --- Test: auto-restart disabled ---"
reset_test_state
AUTO_RESTART=false
MONITORED_SERVICES="com.test.service1"
MOCK_LAUNCHCTL_OUTPUT="-	1	com.test.service1"

result=0
check_services || result=$?
restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "0" "$restart_count" "no restart when auto-restart disabled"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "crashed" "notification about crash when auto-restart off"

# --- Test 6: Service not found in launchctl (missing) ---
echo ""
echo "  --- Test: missing service ---"
reset_test_state
MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1"

result=0
check_services || result=$?
restart_count=$(wc -l < "$RESTART_LOG" | tr -d ' ')
assert_eq "1" "$restart_count" "missing service triggers restart"

# --- Test 7: _get_service_status parsing ---
echo ""
echo "  --- Test: status parsing ---"
reset_test_state

MOCK_LAUNCHCTL_OUTPUT="1234	0	com.test.service1"
status=$(_get_service_status "com.test.service1")
assert_eq "running:1234" "$status" "running service parsed correctly"

MOCK_LAUNCHCTL_OUTPUT="-	1	com.test.service1"
status=$(_get_service_status "com.test.service1")
assert_eq "crashed:1" "$status" "crashed service parsed correctly"

MOCK_LAUNCHCTL_OUTPUT=""
status=$(_get_service_status "com.test.service1")
assert_eq "missing" "$status" "missing service detected"

# --- Test 8: _restart_count_this_hour counts correctly ---
echo ""
echo "  --- Test: restart counter ---"
reset_test_state

rm -f "$SENTINEL_STATE/restart-com.test.counter"
count=$(_restart_count_this_hour "com.test.counter")
assert_eq "0" "$count" "zero when no file"

now=$(date +%s)
old=$(( now - 7200 ))  # 2 hours ago
{
    echo "$old"
    echo "$now"
    echo "$now"
} > "$SENTINEL_STATE/restart-com.test.counter"
count=$(_restart_count_this_hour "com.test.counter")
assert_eq "2" "$count" "counts only recent restarts"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
