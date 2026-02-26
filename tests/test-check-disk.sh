#!/usr/bin/env bash
# ================================================================================
# TEST: check-disk.sh — Disk free space monitoring
# ================================================================================
# Mocks df and sentinel_notify to test disk space detection logic
# without touching real system state.
# ================================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-disk.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs, clean between tests
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-disk-test.XXXXXX)
export SENTINEL_STATE="$TEST_TMPDIR/state"
export SENTINEL_LOGS="$TEST_TMPDIR/logs"
export SENTINEL_CONFIG="$TEST_TMPDIR/config"
mkdir -p "$SENTINEL_STATE" "$SENTINEL_LOGS" "$SENTINEL_CONFIG"

# Source utils (sets up logging, cooldowns, etc.)
source "$REPO_DIR/scripts/sentinel-utils.sh"

# Re-point state/logs to our temp dirs (sentinel-utils.sh overwrites them)
SENTINEL_STATE="$TEST_TMPDIR/state"
SENTINEL_LOGS="$TEST_TMPDIR/logs"

# Source config (sets thresholds)
source "$REPO_DIR/config/sentinel.conf"

# Explicitly set thresholds for tests (sentinel-utils.sh defaults differ from conf)
DISK_WARNING_GB=10
DISK_CRITICAL_GB=5

# =============================================================================
# MOCK STATE VARIABLES — control what mocked commands return
# =============================================================================
MOCK_FREE_GB=63
MOCK_NOTIFY_LOG_FILE="$TEST_TMPDIR/notify.log"
: > "$MOCK_NOTIFY_LOG_FILE"

# =============================================================================
# MOCK FUNCTIONS — override real system commands
# =============================================================================
# NOTE: notify mock writes to FILE instead of variable because check_disk
# may call sentinel_notify inside subshells, and variable changes in
# subshells don't propagate to the parent shell.
# =============================================================================

# Mock df — mimic macOS `df -g /` output with controllable free space
df() {
    echo "Filesystem     1G-blocks  Used Available Capacity iused     ifree %iused  Mounted on"
    echo "/dev/disk3s1s1       228    15       ${MOCK_FREE_GB}    20%  453019 641022240    0%   /"
}

sentinel_notify() {
    echo "$1: $2" >> "$MOCK_NOTIFY_LOG_FILE"
}

# Helpers to read mock logs
get_notify_log() { cat "$MOCK_NOTIFY_LOG_FILE" 2>/dev/null; }

# =============================================================================
# SOURCE THE MODULE UNDER TEST
# =============================================================================
source "$REPO_DIR/scripts/lib/check-disk.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    MOCK_FREE_GB=63
    : > "$MOCK_NOTIFY_LOG_FILE"
    rm -f "$SENTINEL_STATE"/*.cooldown
    : > "$SENTINEL_LOGS/sentinel.log"
}

# =============================================================================
# TEST 1: Plenty of space — NORMAL
# =============================================================================
echo ""
echo "  --- Test 1: Plenty of space ---"
reset_test_state
MOCK_FREE_GB=63

rc=0
check_disk || rc=$?
assert_eq "0" "$rc" "normal disk returns 0"

notify_count=$(wc -l < "$MOCK_NOTIFY_LOG_FILE" | tr -d ' ')
assert_eq "0" "$notify_count" "no alerts when plenty of space"

# =============================================================================
# TEST 2: Warning level (below 10 GB)
# =============================================================================
echo ""
echo "  --- Test 2: Warning level ---"
reset_test_state
MOCK_FREE_GB=8

rc=0
check_disk || rc=$?
assert_eq "1" "$rc" "warning disk returns 1"

notify_content=$(get_notify_log)
assert_contains "$notify_content" "getting low" "warning notification sent"

# =============================================================================
# TEST 3: Critical level (below 5 GB)
# =============================================================================
echo ""
echo "  --- Test 3: Critical level ---"
reset_test_state
MOCK_FREE_GB=3

rc=0
check_disk || rc=$?
assert_eq "2" "$rc" "critical disk returns 2"

notify_content=$(get_notify_log)
assert_contains "$notify_content" "critically low" "critical notification sent"

# =============================================================================
# TEST 4: Exact boundary — at warning threshold (10 GB = normal)
# =============================================================================
echo ""
echo "  --- Test 4: At warning boundary ---"
reset_test_state
MOCK_FREE_GB=10

rc=0
check_disk || rc=$?
assert_eq "0" "$rc" "at warning threshold is still normal"

notify_count=$(wc -l < "$MOCK_NOTIFY_LOG_FILE" | tr -d ' ')
assert_eq "0" "$notify_count" "no alert at exact warning boundary"

# =============================================================================
# TEST 5: Exact boundary — at critical threshold (5 GB = warning, not critical)
# =============================================================================
echo ""
echo "  --- Test 5: At critical boundary ---"
reset_test_state
MOCK_FREE_GB=5

rc=0
check_disk || rc=$?
assert_eq "1" "$rc" "at critical threshold is warning, not critical"

notify_content=$(get_notify_log)
assert_contains "$notify_content" "getting low" "warning (not critical) notification at boundary"

# =============================================================================
# TEST 6: Cooldown prevents repeat critical notification
# =============================================================================
echo ""
echo "  --- Test 6: Cooldown prevents repeat ---"
reset_test_state
MOCK_FREE_GB=3

# First call — sets cooldown
check_disk || true

# Clear notify log, then call again with cooldown still active
: > "$MOCK_NOTIFY_LOG_FILE"
check_disk || true

notify_count=$(wc -l < "$MOCK_NOTIFY_LOG_FILE" | tr -d ' ')
assert_eq "0" "$notify_count" "cooldown prevents repeat critical notification"

# =============================================================================
# TEST 7: Various free space values behave correctly
# =============================================================================
echo ""
echo "  --- Test 7: 42 GB free is normal ---"
reset_test_state
MOCK_FREE_GB=42

rc=0
check_disk || rc=$?
assert_eq "0" "$rc" "42 GB free is normal"

notify_count=$(wc -l < "$MOCK_NOTIFY_LOG_FILE" | tr -d ' ')
assert_eq "0" "$notify_count" "no alerts at 42 GB free"

# =============================================================================
# TEST 8: Logging — critical level writes to log file
# =============================================================================
echo ""
echo "  --- Test 8: Logging ---"
reset_test_state
MOCK_FREE_GB=3

check_disk || true

log_content=$(cat "$SENTINEL_LOGS/sentinel.log" 2>/dev/null || true)
assert_contains "$log_content" "CRITICAL" "critical level logged"
assert_contains "$log_content" "Disk" "disk mentioned in log"

# =============================================================================
# TEST 9: Warning cooldown prevents spam notifications
# =============================================================================
echo ""
echo "  --- Test 9: Warning cooldown prevents spam ---"
reset_test_state
MOCK_FREE_GB=8

# First call — should notify
rc=0
check_disk || rc=$?
assert_eq "1" "$rc" "first warning returns 1"
assert_contains "$(get_notify_log)" "getting low" "first warning sends notification"

# Second call — on cooldown, should NOT notify again
: > "$MOCK_NOTIFY_LOG_FILE"
rc=0
check_disk || rc=$?
assert_eq "1" "$rc" "second warning returns 1"

notify_count=$(wc -l < "$MOCK_NOTIFY_LOG_FILE" | tr -d ' ')
assert_eq "0" "$notify_count" "second warning skips notification (cooldown)"

# =============================================================================
# TEST 10: _get_free_gb returns correct parsed value
# =============================================================================
echo ""
echo "  --- Test 10: _get_free_gb parsing ---"
reset_test_state

MOCK_FREE_GB=99
result=$(_get_free_gb)
assert_eq "99" "$result" "_get_free_gb parses 99 correctly"

MOCK_FREE_GB=0
result=$(_get_free_gb)
assert_eq "0" "$result" "_get_free_gb parses 0 correctly"

MOCK_FREE_GB=1
result=$(_get_free_gb)
assert_eq "1" "$result" "_get_free_gb parses 1 correctly"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
