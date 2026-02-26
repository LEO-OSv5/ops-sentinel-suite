#!/usr/bin/env bash
# Test: check-backups.sh detects stale backup channels
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== test-check-backups.sh ==="

# =============================================================================
# TEST ISOLATION: temp dirs for state/logs
# =============================================================================
TEST_TMPDIR=$(mktemp -d /tmp/sentinel-backups-test.XXXXXX)
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

# Track notifications via file (subshell-safe)
NOTIFY_LOG="$TEST_TMPDIR/notify.log"
: > "$NOTIFY_LOG"

sentinel_notify() { echo "$1: $2" >> "$NOTIFY_LOG"; }

# =============================================================================
# MOCK FUNCTIONS
# =============================================================================

# Mock launchctl (sync agent present by default)
MOCK_LAUNCHCTL_SYNC="1234	0	com.ops.sync"
launchctl() {
    if [[ "$1" == "list" ]]; then
        echo "$MOCK_LAUNCHCTL_SYNC"
    fi
}

# Mock mount (OPS-mini mounted by default)
MOCK_MOUNT_OUTPUT="/dev/disk4s1 on /Volumes/OPS-mini (apfs, local, nodev, nosuid)"
mount() {
    echo "$MOCK_MOUNT_OUTPUT"
}

# Mock git repo for testing (fresh commit)
MOCK_REPO="$TEST_TMPDIR/mock-repo"
mkdir -p "$MOCK_REPO"
git -C "$MOCK_REPO" init -q 2>/dev/null
git -C "$MOCK_REPO" config user.email "test@test.com" 2>/dev/null
git -C "$MOCK_REPO" config user.name "Test" 2>/dev/null
git -C "$MOCK_REPO" commit --allow-empty -m "test" -q 2>/dev/null

# Mock OPS-mini path (fresh directory for stat checks)
MOCK_OPS_MINI="$TEST_TMPDIR/mock-opsmini"
mkdir -p "$MOCK_OPS_MINI"
OPS_MINI_PATH="$MOCK_OPS_MINI"

# Override config values for testing
GITHUB_REPOS="$MOCK_REPO"
OPS_SYNC_STALE_MINUTES=30
GITHUB_STALE_HOURS=24
OPS_MINI_STALE_HOURS=48

# Source the module under test
source "$REPO_DIR/scripts/lib/check-backups.sh"

# =============================================================================
# HELPER: Reset test state between test cases
# =============================================================================
reset_test_state() {
    : > "$NOTIFY_LOG"
    MOCK_LAUNCHCTL_SYNC="1234	0	com.ops.sync"
    MOCK_MOUNT_OUTPUT="/dev/disk4s1 on /Volumes/OPS-mini (apfs, local, nodev, nosuid)"
    GITHUB_REPOS="$MOCK_REPO"
    OPS_MINI_PATH="$MOCK_OPS_MINI"
    clear_cooldown "backup-github"
    clear_cooldown "backup-sync"
    clear_cooldown "backup-opsmini"
    clear_cooldown "backup-opsmini-stale"
    : > "$SENTINEL_LOGS/sentinel.log"
}

# --- Test 1: All channels fresh ---
echo ""
echo "  --- Test: all channels fresh ---"
reset_test_state

result=0
check_backups || result=$?
assert_eq "0" "$result" "all fresh returns 0"

notify_count=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
assert_eq "0" "$notify_count" "no alerts when all fresh"

# --- Test 2: Stale GitHub repo ---
echo ""
echo "  --- Test: stale GitHub repo ---"
reset_test_state

# Create a repo with an old commit
STALE_REPO="$TEST_TMPDIR/stale-repo"
mkdir -p "$STALE_REPO"
git -C "$STALE_REPO" init -q 2>/dev/null
git -C "$STALE_REPO" config user.email "test@test.com" 2>/dev/null
git -C "$STALE_REPO" config user.name "Test" 2>/dev/null
GIT_COMMITTER_DATE="2026-01-01T00:00:00" git -C "$STALE_REPO" commit --allow-empty -m "old" -q --date="2026-01-01T00:00:00" 2>/dev/null
GITHUB_REPOS="$STALE_REPO"

result=0
check_backups || result=$?
assert_eq "1" "$result" "stale repo returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "pushed" "notification mentions push staleness"

# --- Test 3: OPS-mini not mounted ---
echo ""
echo "  --- Test: OPS-mini not mounted ---"
reset_test_state
MOCK_MOUNT_OUTPUT="/dev/disk1s1 on / (apfs, local)"

result=0
check_backups || result=$?
assert_eq "1" "$result" "unmounted OPS-mini returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "OPS-mini disconnected" "notification about OPS-mini"

# --- Test 4: OPS sync agent not running ---
echo ""
echo "  --- Test: OPS sync agent missing ---"
reset_test_state
MOCK_LAUNCHCTL_SYNC=""

result=0
check_backups || result=$?
assert_eq "1" "$result" "missing sync agent returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "sync" "notification mentions sync"

# --- Test 5: Clean run returns 0 on fresh state ---
echo ""
echo "  --- Test: clean run returns 0 on fresh state ---"
reset_test_state

result=0
check_backups || result=$?
assert_eq "0" "$result" "clean run returns 0"

# --- Test 6: Cooldown prevents repeated notifications ---
echo ""
echo "  --- Test: cooldown prevents repeat notifications ---"
reset_test_state
MOCK_LAUNCHCTL_SYNC=""

# First call triggers alert and sets cooldown
result=0
check_backups || result=$?
assert_eq "1" "$result" "first call with missing sync returns 1"

# Clear the notify log but keep cooldown active
: > "$NOTIFY_LOG"

# Second call should still return 1 but not re-notify
result=0
check_backups || result=$?
assert_eq "1" "$result" "second call still returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_not_contains "$notify_content" "not registered" "cooldown prevents repeat sync notification"

# --- Test 7: Multiple channels can fail simultaneously ---
echo ""
echo "  --- Test: multiple channels fail simultaneously ---"
reset_test_state
MOCK_LAUNCHCTL_SYNC=""
MOCK_MOUNT_OUTPUT="/dev/disk1s1 on / (apfs, local)"
GITHUB_REPOS="$STALE_REPO"

result=0
check_backups || result=$?
assert_eq "1" "$result" "multiple failures still returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "sync" "notification includes sync failure"
assert_contains "$notify_content" "OPS-mini disconnected" "notification includes OPS-mini failure"
assert_contains "$notify_content" "pushed" "notification includes stale repo"

# --- Test 8: Non-existent repo path is skipped gracefully ---
echo ""
echo "  --- Test: non-existent repo path is skipped ---"
reset_test_state
GITHUB_REPOS="/tmp/this-does-not-exist-$$"

result=0
check_backups || result=$?
assert_eq "0" "$result" "non-existent repo path returns 0 (skipped)"

# --- Test 9: Log file records warnings ---
echo ""
echo "  --- Test: log file records warnings ---"
reset_test_state
MOCK_LAUNCHCTL_SYNC=""

result=0
check_backups || result=$?

log_content=$(cat "$SENTINEL_LOGS/sentinel.log")
assert_contains "$log_content" "sync agent not registered" "log records sync warning"
assert_contains "$log_content" "WARN" "log uses WARN level"

# --- Test 10: Stale OPS-mini triggers notification ---
echo ""
echo "  --- Test: stale OPS-mini triggers notification ---"
reset_test_state

# Create a directory and backdate it
STALE_MINI="$TEST_TMPDIR/stale-opsmini"
mkdir -p "$STALE_MINI"
# Set mod time to 72 hours ago (exceeds 48h threshold)
touch -t "$(date -v-72H '+%Y%m%d%H%M.%S')" "$STALE_MINI"
OPS_MINI_PATH="$STALE_MINI"

result=0
check_backups || result=$?
assert_eq "1" "$result" "stale OPS-mini returns 1"

notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "OPS-mini backup is" "notification mentions stale OPS-mini age"

# --- Test 11: OPS-mini mounted but path missing is OK ---
echo ""
echo "  --- Test: OPS-mini mounted but path missing is OK ---"
reset_test_state
OPS_MINI_PATH="/tmp/nonexistent-opsmini-path-$$"

result=0
check_backups || result=$?
assert_eq "0" "$result" "mounted but path missing returns 0 (skip freshness)"

# =============================================================================
# CLEANUP
# =============================================================================
rm -rf "$TEST_TMPDIR"

echo ""
test_summary
